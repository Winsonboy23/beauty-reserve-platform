// POST /api/notify/deposit-paid
// body: { bookingId: string }
// 老闆按「標訂金已付」時呼叫;同時寄 Email + LINE (各自獨立 idempotent)
import { createClient } from '@supabase/supabase-js'
import { sendEmail } from '~/server/utils/email'
import { linePush } from '~/server/utils/line'
import { depositPaidEmail, type BookingForEmail } from '~/server/utils/email-templates'

export default defineEventHandler(async (event) => {
  const body = await readBody<{ bookingId: string }>(event)
  if (!body?.bookingId) {
    throw createError({ statusCode: 400, statusMessage: 'missing bookingId' })
  }

  const supabaseUrl = process.env.SUPABASE_URL!
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) {
    return { ok: true, skipped: 'no service_role' }
  }

  const admin = createClient(supabaseUrl, serviceKey)
  const { data, error } = await admin.rpc('notify_booking_payload', { p_booking_id: body.bookingId })
  if (error || !data || (Array.isArray(data) && !data.length)) {
    throw createError({ statusCode: 404, statusMessage: 'booking not found' })
  }
  const p = (Array.isArray(data) ? data[0] : data) as any

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
      .eq('kind', 'deposit_paid')
      .maybeSingle()
    if (!existing) {
      const booking: BookingForEmail = {
        id: p.short_ref ? body.bookingId : body.bookingId,
        start_at: p.start_at_local + '+00:00' /* fallback,後續用 fmtTime 重格 */,
        end_at: p.start_at_local + '+00:00',
        duration_minutes: p.duration_minutes,
        status: 'confirmed',
        deposit_amount: Number(p.deposit_amount),
        deposit_status: 'paid',
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
      // 直接拉 booking.start_at (UTC) 取代 local 字串
      const { data: bRow } = await admin
        .from('bookings').select('start_at, end_at').eq('id', body.bookingId).maybeSingle()
      if (bRow) {
        booking.start_at = bRow.start_at
        booking.end_at = bRow.end_at
      }

      const { subject, html, text } = depositPaidEmail(booking, origin)
      const r = await sendEmail({ to: p.customer_email, subject, html, text })
      await admin.from('notification_log').insert({
        tenant_id: p.tenant_id,
        booking_id: body.bookingId,
        channel: 'email',
        kind: 'deposit_paid',
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
      .eq('kind', 'deposit_paid')
      .maybeSingle()
    if (!existing) {
      const lines = [
        `✅ 訂金已收訖`,
        `${p.tenant_name}`,
        ``,
        `編號: ${p.short_ref}`,
        `時間: ${p.start_at_local}`,
        `服務: ${p.service_name} (${p.duration_minutes} 分)`,
        `設計師: ${p.staff_name}`,
        `訂金: $${p.deposit_amount} 已收`,
        ``,
        `請準時到店。改期 / 取消: ${origin}/manage/${body.bookingId}?t=${p.manage_token}`,
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
        kind: 'deposit_paid',
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
