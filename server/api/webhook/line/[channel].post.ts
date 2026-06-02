// POST /api/webhook/line/[channel]
// LINE Messaging API webhook receiver.
// channel = tenants.line_channel_id (urls per tenant)
//
// 處理:
//   - follow: 加好友 → 存 line_pending_binding, 回覆要求電話
//   - message (text 含電話): 找 member by phone → 綁 line_user_id, 回覆已綁定
//   - message (其他): 提示傳電話
//
// 安全: 驗 X-Line-Signature header (HMAC-SHA256 with channel_secret)
//
// LINE 的 events 通常一個 request 含多筆 (push 後 LINE 可能 batch)
//
// LINE webhook docs: https://developers.line.biz/en/reference/messaging-api/#webhooks

import { createHmac, timingSafeEqual } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'
import { linePush } from '~/server/utils/line'

interface LineEvent {
  type: string
  source?: { type?: string; userId?: string }
  message?: { type?: string; text?: string }
  replyToken?: string
  timestamp?: number
}

export default defineEventHandler(async (event) => {
  const channelId = getRouterParam(event, 'channel')
  if (!channelId) {
    throw createError({ statusCode: 400, statusMessage: 'missing channel' })
  }

  const supabaseUrl = process.env.SUPABASE_URL!
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) {
    throw createError({ statusCode: 503, statusMessage: 'service_role not configured' })
  }
  const admin = createClient(supabaseUrl, serviceKey)

  // 找 tenant
  const { data: trow, error: terr } = await admin.rpc('tenant_by_line_channel', { p_channel_id: channelId })
  if (terr || !trow || (Array.isArray(trow) && !trow.length)) {
    throw createError({ statusCode: 404, statusMessage: 'channel not registered' })
  }
  const t = (Array.isArray(trow) ? trow[0] : trow) as any
  const tenantId = t.tenant_id as string
  const channelSecret = t.channel_secret as string | null
  const accessToken = t.access_token as string | null

  // 取得原始 body 做 signature 驗證
  const rawBody = await readRawBody(event, 'utf8') ?? ''
  if (channelSecret) {
    const signature = getRequestHeader(event, 'x-line-signature') ?? ''
    const expected = createHmac('sha256', channelSecret).update(rawBody).digest('base64')
    try {
      const a = Buffer.from(signature)
      const b = Buffer.from(expected)
      if (a.length !== b.length || !timingSafeEqual(a, b)) {
        throw createError({ statusCode: 401, statusMessage: 'invalid signature' })
      }
    } catch {
      throw createError({ statusCode: 401, statusMessage: 'invalid signature' })
    }
  }

  const parsed = rawBody ? JSON.parse(rawBody) : {}
  const events: LineEvent[] = parsed.events ?? []

  // 預掃: 確認 LINE 驗證 webhook URL (空 events) 也 200
  if (events.length === 0) return { ok: true, info: 'verify ping' }

  const replyMessages: Array<{ replyToken: string; text: string }> = []

  for (const ev of events) {
    const userId = ev.source?.userId
    if (!userId) continue

    if (ev.type === 'follow') {
      // 加好友 → 存暫存,等他傳電話
      await admin.from('line_pending_binding').upsert({
        tenant_id: tenantId, line_user_id: userId,
      }, { onConflict: 'tenant_id,line_user_id' })
      if (ev.replyToken) {
        replyMessages.push({
          replyToken: ev.replyToken,
          text: '歡迎加入!\n\n請傳送您過去預約用的電話號碼,我們會把您的 LINE 帳號綁定,之後預約資訊會自動透過 LINE 通知。',
        })
      }
      continue
    }

    if (ev.type === 'message' && ev.message?.type === 'text' && ev.message.text) {
      const text = ev.message.text.trim()
      // 抽出數字當電話 (台灣電話 8-10 碼)
      const digits = text.replace(/[^0-9]/g, '')
      if (digits.length >= 8 && digits.length <= 15) {
        // 試綁定
        const { data: bindRes, error: bindErr } = await admin.rpc('bind_line_user', {
          p_tenant_id: tenantId,
          p_phone: digits,
          p_line_user_id: userId,
        })
        if (bindErr) {
          if (ev.replyToken) {
            replyMessages.push({
              replyToken: ev.replyToken,
              text: '綁定失敗,請聯絡店家確認。',
            })
          }
        } else {
          const row = Array.isArray(bindRes) ? bindRes[0] : bindRes
          await admin.from('line_pending_binding')
            .delete().eq('tenant_id', tenantId).eq('line_user_id', userId)
          if (ev.replyToken) {
            const msg = row?.was_existing
              ? `✓ 已綁定!您的預約資訊之後會透過 LINE 通知。`
              : `✓ 已記錄您的電話 (${digits})。下次到店預約後,系統會自動將你的紀錄跟此 LINE 帳號連結。`
            replyMessages.push({ replyToken: ev.replyToken, text: msg })
          }
        }
      } else {
        if (ev.replyToken) {
          replyMessages.push({
            replyToken: ev.replyToken,
            text: '請傳送您的電話號碼以完成綁定 (純數字即可)。',
          })
        }
      }
    }
  }

  // 用 reply API 回覆 (而非 push,reply 免費且無配額)
  if (replyMessages.length > 0 && accessToken) {
    for (const r of replyMessages) {
      try {
        await $fetch('https://api.line.me/v2/bot/message/reply', {
          method: 'POST',
          headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          body: { replyToken: r.replyToken, messages: [{ type: 'text', text: r.text }] },
        })
      } catch (e: any) {
        console.warn('LINE reply failed', e?.message ?? e)
      }
    }
  }

  return { ok: true, processed: events.length, replied: replyMessages.length }
})
