// POST /api/notify/booking-completed
// body: { bookingId: string }
// 老闆按「完成」並輸入 actual_amount 後觸發。
// 寄 Email + LINE,並把本次累積點數一併寫進訊息。
import { createClient } from '@supabase/supabase-js'
import { sendEmail } from '~/server/utils/email'
import { linePush } from '~/server/utils/line'
import { bookingCompletedEmail, type BookingForEmail } from '~/server/utils/email-templates'

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

  // 取本次賺的點數 (loyalty_transactions where booking_id + earned_from_booking)
  const { data: txRow } = await admin
    .from('loyalty_transactions')
    .select('points')
    .eq('booking_id', body.bookingId)
    .eq('source', 'earned_from_booking')
    .maybeSingle()
  const pointsEarned = txRow?.points ?? 0

  // 拿 booking start_at / end_at (RPC 沒回這兩個 UTC 值)
  const { data: bRow } = await admin
    .from('bookings').select('start_at, end_at').eq('id', body.bookingId).maybeSingle()

  const origin = getRequestHeader(event, 'origin')
    || `${getRequestProtocol(event)}://${getRequestHost(event)}`

  const result: { email?: any; line?: any } = {}

  // ----- Email -----
  if (p.customer_email && bRow) {
    const { data: existing } = await admin
      .from('notification_log')
      .select('id')
      .eq('booking_id', body.bookingId)
      .eq('channel', 'email')
      .eq('kind', 'booking_completed')
      .maybeSingle()
    if (!existing) {
      const booking: BookingForEmail = {
        id: body.bookingId,
        start_at: bRow.start_at,
        end_at: bRow.end_at,
        duration_minutes: p.duration_minutes,
        status: 'completed',
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
      const { subject, html, text } = bookingCompletedEmail(booking, origin, pointsEarned)
      const r = await sendEmail({ to: p.customer_email, subject, html, text })
      await admin.from('notification_log').insert({
        tenant_id: p.tenant_id,
        booking_id: body.bookingId,
        channel: 'email',
        kind: 'booking_completed',
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
      .eq('kind', 'booking_completed')
      .maybeSingle()
    if (!existing) {
      const lines = [
        `🌸 ${p.tenant_name}`,
        `感謝光臨!`,
        ``,
        `服務: ${p.service_name} (${p.duration_minutes} 分)`,
        `設計師: ${p.staff_name}`,
      ]
      if (pointsEarned > 0) {
        lines.push('', `🎁 累積點數 +${pointsEarned},下次可折抵`)
      }
      lines.push('', '期待下次再見!')
      const r = await linePush({
        channelAccessToken: p.tenant_line_channel_access_token,
        to: p.member_line_user_id,
        messages: [{ type: 'text', text: lines.join('\n') }],
      })
      await admin.from('notification_log').insert({
        tenant_id: p.tenant_id,
        booking_id: body.bookingId,
        channel: 'line',
        kind: 'booking_completed',
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
