// POST /api/notify/booking-line
// body: { bookingId: string }
//
// 用 service_role 透過 notify_booking_payload RPC 拿 token + user_id;
// 沒設 token 或沒綁 user_id → skip (回 200 但 reason)。
// 失敗不 fatal — 預約已建立,通知失敗只 log。

import { createClient } from '@supabase/supabase-js'
import { linePush } from '~/server/utils/line'

export default defineEventHandler(async (event) => {
  const body = await readBody<{ bookingId: string }>(event)
  if (!body?.bookingId) {
    throw createError({ statusCode: 400, statusMessage: 'missing bookingId' })
  }

  const supabaseUrl = process.env.SUPABASE_URL!
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) {
    // 沒 service_role → 沒法拿 token, 直接 skip
    return { ok: true, skipped: 'no service_role' }
  }

  const admin = createClient(supabaseUrl, serviceKey)

  // 拿 booking + tenant + member 整個 payload
  const { data, error } = await admin.rpc('notify_booking_payload', { p_booking_id: body.bookingId })
  if (error || !data || (Array.isArray(data) && !data.length)) {
    throw createError({ statusCode: 404, statusMessage: 'booking not found' })
  }
  const p = (Array.isArray(data) ? data[0] : data) as any

  // 沒設 LINE channel token → skip
  if (!p.tenant_line_channel_access_token) {
    return { ok: true, skipped: 'tenant has no LINE token' }
  }
  // 該客人未綁定 LINE user id → skip
  if (!p.member_line_user_id) {
    return { ok: true, skipped: 'member has no LINE user_id' }
  }

  // idempotency check
  const { data: existing } = await admin
    .from('notification_log')
    .select('id')
    .eq('booking_id', body.bookingId)
    .eq('channel', 'line')
    .eq('kind', 'booking_created')
    .maybeSingle()
  if (existing) {
    return { ok: true, skipped: 'already sent' }
  }

  // 組訊息 — LINE OA push 限制每則 text <= 5000 字 (沒限制條數,但盡量精簡)
  const needDeposit = Number(p.deposit_amount) > 0 && p.deposit_status === 'pending'
  const lines: string[] = [
    `🌸 ${p.tenant_name} 預約確認`,
    ``,
    `編號: ${p.short_ref}`,
    `時間: ${p.start_at_local}`,
    `服務: ${p.service_name} (${p.duration_minutes} 分)`,
    `設計師: ${p.staff_name}`,
  ]
  if (needDeposit) {
    lines.push('', `💰 請於 24 小時內轉帳訂金 $${p.deposit_amount}`)
    if (p.tenant_bank_name) lines.push(`銀行: ${p.tenant_bank_name}`)
    if (p.tenant_bank_account_no) lines.push(`帳號: ${p.tenant_bank_account_no}`)
    if (p.tenant_bank_account_holder) lines.push(`戶名: ${p.tenant_bank_account_holder}`)
    lines.push(`備註填: ${p.short_ref}`)
  }
  // manage link
  const origin = getRequestHeader(event, 'origin')
    || `${getRequestProtocol(event)}://${getRequestHost(event)}`
  lines.push('', `改期 / 取消: ${origin}/manage/${body.bookingId}?t=${p.manage_token}`)

  const result = await linePush({
    channelAccessToken: p.tenant_line_channel_access_token,
    to: p.member_line_user_id,
    messages: [{ type: 'text', text: lines.join('\n') }],
  })

  // 寫 log
  await admin.from('notification_log').insert({
    tenant_id: p.tenant_id,
    booking_id: body.bookingId,
    channel: 'line',
    kind: 'booking_created',
    recipient: p.member_line_user_id,
    status: result.ok ? 'sent' : 'failed',
    error_message: result.error,
  })
  // 配額計數 (寄成功時才加)
  if (result.ok && !result.simulated) {
    await admin.rpc('increment_line_msgs', { p_tenant_id: p.tenant_id }).catch(() => {
      // 沒這支 RPC 也沒關係, 直接 increment 欄位
    })
    await admin
      .from('tenants')
      .update({ line_msgs_used_this_month: (p.line_msgs_used_this_month ?? 0) + 1 })
      .eq('id', p.tenant_id)
      .then(() => {}, () => {})
  }

  return {
    ok: result.ok,
    simulated: result.simulated,
    error: result.error,
  }
})
