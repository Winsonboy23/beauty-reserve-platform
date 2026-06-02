// POST /api/notify/booking-reminder
// body: { bookingId: string }
// 可被 (1) pg_cron 自動觸發 (帶 X-Dispatch-Secret), (2) 後台手動觸發 (沒 secret)
//
// 安全: 沒 secret 的請求允許,但仍走 notification_log idempotency,
// 多次觸發只會寄一次。
import { createClient } from '@supabase/supabase-js'
import { sendEmail } from '~/server/utils/email'
import { linePush } from '~/server/utils/line'
import { bookingReminderEmail, type BookingForEmail } from '~/server/utils/email-templates'

export default defineEventHandler(async (event) => {
  const body = await readBody<{ bookingId: string }>(event)
  if (!body?.bookingId) {
    throw createError({ statusCode: 400, statusMessage: 'missing bookingId' })
  }
  const supabaseUrl = process.env.SUPABASE_URL!
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) return { ok: true, skipped: 'no service_role' }

  const admin = createClient(supabaseUrl, serviceKey)
  const { data, error } = await admin.rpc('notify_booking_payload', { p_booking_id: body.bookingId })
  if (error || !data || (Array.isArray(data) && !data.length)) {
    throw createError({ statusCode: 404, statusMessage: 'booking not found' })
  }
  const p = (Array.isArray(data) ? data[0] : data) as any

  // 拿 start_at / end_at (RPC 沒回 UTC)
  const { data: bRow } = await admin
    .from('bookings').select('start_at, end_at, status').eq('id', body.bookingId).maybeSingle()
  if (!bRow) {
    throw createError({ statusCode: 404, statusMessage: 'booking not found' })
  }
  // 已取消 / 完成 → 不寄
  if (['cancelled', 'completed', 'no_show'].includes(bRow.status)) {
    return { ok: true, skipped: 'booking not active' }
  }

  const origin = getRequestHeader(event, 'origin')
    || `${getRequestProtocol(event)}://${getRequestHost(event)}`
  const result: { email?: any; line?: any } = {}

  // ----- Email -----
  if (p.customer_email) {
    const { data: existing } = await admin
      .from('notification_log')
      .select('id')
      .eq('booking_id', body.bookingId)
      .eq('channel', 'email')
      .eq('kind', 'reminder_24h')
      .maybeSingle()
    if (!existing) {
      const booking: BookingForEmail = {
        id: body.bookingId,
        start_at: bRow.start_at,
        end_at: bRow.end_at,
        duration_minutes: p.duration_minutes,
        status: bRow.status,
        deposit_amount: Number(p.deposit_amount),
        deposit_status: p.deposit_status,
        staff_name: p.staff_name,
        service_name: p.service_name,
        service_price: 0,
        tenant_name: p.tenant_name,
        tenant_timezone: p.tenant_timezone,
        tenant_bank_name: p.tenant_bank_name,
        tenant_bank_account_no: p.tenant_bank_account_no,
        tenant_bank_account_holder: p.tenant_bank_account_holder,
        tenant_bank_transfer_note: p.tenant_bank_transfer_note,
        manage_token: p.manage_token,
        customer_email: p.customer_email,
        customer_name: p.customer_name,
      }
      const { subject, html, text } = bookingReminderEmail(booking, origin)
      const r = await sendEmail({ to: p.customer_email, subject, html, text })
      await admin.from('notification_log').insert({
        tenant_id: p.tenant_id,
        booking_id: body.bookingId,
        channel: 'email',
        kind: 'reminder_24h',
        recipient: p.customer_email,
        status: r.ok ? 'sent' : 'failed',
        provider_ref: r.id,
        error_message: r.error,
      })
      result.email = { ok: r.ok, simulated: r.simulated, error: r.error }
    } else {
      result.email = { skipped: 'already sent' }
    }
  }

  // ----- LINE -----
  if (p.tenant_line_channel_access_token && p.member_line_user_id) {
    const { data: existing } = await admin
      .from('notification_log')
      .select('id')
      .eq('booking_id', body.bookingId)
      .eq('channel', 'line')
      .eq('kind', 'reminder_24h')
      .maybeSingle()
    if (!existing) {
      const lines = [
        `⏰ 預約提醒`,
        `${p.tenant_name}`,
        ``,
        `編號: ${p.short_ref}`,
        `時間: ${p.start_at_local}`,
        `服務: ${p.service_name} (${p.duration_minutes} 分)`,
        `設計師: ${p.staff_name}`,
        ``,
        `改期 / 取消: ${origin}/manage/${body.bookingId}?t=${p.manage_token}`,
      ]
      const r = await linePush({
        channelAccessToken: p.tenant_line_channel_access_token,
        to: p.member_line_user_id,
        messages: [{ type: 'text', text: lines.join('\n') }],
      })
      await admin.from('notification_log').insert({
        tenant_id: p.tenant_id,
        booking_id: body.bookingId,
        channel: 'line',
        kind: 'reminder_24h',
        recipient: p.member_line_user_id,
        status: r.ok ? 'sent' : 'failed',
        error_message: r.error,
      })
      result.line = { ok: r.ok, simulated: r.simulated, error: r.error }
    } else {
      result.line = { skipped: 'already sent' }
    }
  }

  return { ok: true, result }
})
