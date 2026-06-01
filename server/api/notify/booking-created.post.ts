// POST /api/notify/booking-created
// body: { bookingId: string, manageToken: string, customerEmail: string, customerName: string }
//
// 設計:
//   1. 用 anon supabase client + manage_token 經 get_booking_for_manage RPC 拿資料
//      → 不暴露 service_role,也不能讀別人的預約 (token 認證)
//   2. 寄 email 後,用 service_role 寫 notification_log (idempotent unique)
//   3. 失敗不 fatal — 預約已建立,通知失敗不該回滾客人的預約
//
// 觸發點: /book submit() 成功後 fire-and-forget 呼叫此 endpoint。
// 之後 LINE / SMS 可以複用同樣模式。

import { createClient } from '@supabase/supabase-js'
import { sendEmail } from '~/server/utils/email'
import { bookingCreatedEmail, type BookingForEmail } from '~/server/utils/email-templates'

export default defineEventHandler(async (event) => {
  const body = await readBody<{
    bookingId: string
    manageToken: string
    customerEmail: string
    customerName: string
  }>(event)

  if (!body?.bookingId || !body?.manageToken) {
    throw createError({ statusCode: 400, statusMessage: 'missing booking_id / token' })
  }
  if (!body.customerEmail) {
    // 沒填 email,直接 200 不寄 (不視為錯誤)
    return { ok: true, skipped: 'no email provided' }
  }

  const config = useRuntimeConfig()
  const supabaseUrl = config.public.supabaseUrl as string || process.env.SUPABASE_URL!
  const anonKey = config.public.supabaseKey as string || process.env.SUPABASE_KEY!
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

  // 1) 用 anon + token 拿預約資料 (RPC 已做 token 驗證)
  const anon = createClient(supabaseUrl, anonKey)
  const { data, error } = await anon.rpc('get_booking_for_manage', {
    p_booking_id: body.bookingId,
    p_token: body.manageToken,
  })
  if (error || !data || (Array.isArray(data) && !data.length)) {
    throw createError({ statusCode: 404, statusMessage: 'booking not found or invalid token' })
  }
  const row = (Array.isArray(data) ? data[0] : data) as any

  const booking: BookingForEmail = {
    id: row.id,
    start_at: row.start_at,
    end_at: row.end_at,
    duration_minutes: row.duration_minutes,
    status: row.status,
    deposit_amount: Number(row.deposit_amount),
    deposit_status: row.deposit_status,
    staff_name: row.staff_name,
    service_name: row.service_name,
    service_price: Number(row.service_price),
    tenant_name: row.tenant_name,
    tenant_timezone: row.tenant_timezone,
    tenant_bank_name: row.tenant_bank_name,
    tenant_bank_account_no: row.tenant_bank_account_no,
    tenant_bank_account_holder: row.tenant_bank_account_holder,
    tenant_bank_transfer_note: row.tenant_bank_transfer_note,
    manage_token: body.manageToken,
    customer_email: body.customerEmail,
    customer_name: body.customerName,
  }

  // 2) idempotency 檢查 (有 service_role 才做; 否則跳過)
  let alreadySent = false
  if (serviceKey) {
    const admin = createClient(supabaseUrl, serviceKey)
    const { data: existing } = await admin
      .from('notification_log')
      .select('id')
      .eq('booking_id', body.bookingId)
      .eq('channel', 'email')
      .eq('kind', 'booking_created')
      .maybeSingle()
    if (existing) alreadySent = true
  }
  if (alreadySent) return { ok: true, skipped: 'already sent' }

  // 3) 寄信
  const reqOrigin = getRequestHeader(event, 'origin')
    || `${getRequestProtocol(event)}://${getRequestHost(event)}`
  const { subject, html, text } = bookingCreatedEmail(booking, reqOrigin)
  const result = await sendEmail({ to: body.customerEmail, subject, html, text })

  // 4) 寫 log (有 service_role 才寫; dev mode 沒 key 就跳過)
  if (serviceKey) {
    const admin = createClient(supabaseUrl, serviceKey)
    await admin.from('notification_log').insert({
      tenant_id: row.tenant_id,
      booking_id: body.bookingId,
      channel: 'email',
      kind: 'booking_created',
      recipient: body.customerEmail,
      status: result.ok ? 'sent' : 'failed',
      provider_ref: result.id,
      error_message: result.error,
    })
  }

  return { ok: result.ok, simulated: result.simulated, error: result.error }
})
