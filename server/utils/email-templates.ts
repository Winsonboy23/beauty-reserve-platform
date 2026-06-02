// Email 模板 — 純函式回傳 HTML / Text。
// 目前在 Nuxt server runtime 跑,沒裝模板引擎,直接字串拼。
// 設計: 對齊網站米黃 cream 風,簡單表格 layout,handler 也支援文字 fallback。

export interface BookingForEmail {
  id: string
  start_at: string
  end_at: string
  duration_minutes: number
  status: string
  deposit_amount: number
  deposit_status: string
  staff_name: string
  service_name: string
  service_price: number
  tenant_name: string
  tenant_timezone: string
  tenant_bank_name: string | null
  tenant_bank_account_no: string | null
  tenant_bank_account_holder: string | null
  tenant_bank_transfer_note: string | null
  manage_token: string
  customer_email: string
  customer_name: string
}

function fmtTime(iso: string, tz: string) {
  return new Date(iso).toLocaleString('zh-TW', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
function shortRef(id: string) { return id.slice(0, 6).toUpperCase() }

export function bookingCreatedEmail(b: BookingForEmail, siteOrigin: string) {
  const time = fmtTime(b.start_at, b.tenant_timezone)
  const ref = shortRef(b.id)
  const manageUrl = `${siteOrigin}/manage/${b.id}?t=${b.manage_token}`
  const needDeposit = Number(b.deposit_amount) > 0 && b.deposit_status === 'pending'

  const text = [
    `${b.customer_name} 您好,`,
    ``,
    `您在「${b.tenant_name}」的預約已收到:`,
    ``,
    `編號: ${ref}`,
    `時間: ${time}`,
    `服務: ${b.service_name} (${b.duration_minutes} 分)`,
    `設計師: ${b.staff_name}`,
    ``,
    needDeposit
      ? `本服務需收訂金 $${b.deposit_amount},請於 24 小時內完成轉帳:\n`
        + `  銀行: ${b.tenant_bank_name ?? '—'}\n`
        + `  帳號: ${b.tenant_bank_account_no ?? '—'}\n`
        + `  戶名: ${b.tenant_bank_account_holder ?? '—'}\n`
        + `  備註: 請填預約編號 ${ref}\n`
        + (b.tenant_bank_transfer_note ? `  說明: ${b.tenant_bank_transfer_note}\n` : '')
        + `逾時系統會自動釋放此時段。`
      : `本服務無須訂金,請準時到店。`,
    ``,
    `若需改期或取消,請使用此連結:`,
    manageUrl,
    ``,
    `${b.tenant_name}`,
  ].join('\n')

  const html = `
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${escape(b.tenant_name)} 預約確認</title></head>
<body style="margin:0; background:#f3eedd; font-family:-apple-system,BlinkMacSystemFont,'PingFang TC',sans-serif; color:#1a1a1a;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3eedd; padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px; background:#fdfaf1; border:1px solid #2b2b2b; border-radius:14px; overflow:hidden;">
        <tr><td style="padding:24px 28px 8px;">
          <h1 style="margin:0 0 8px; font-family:Georgia,serif; font-weight:400; font-size:24px;">${escape(b.tenant_name)}</h1>
          <p style="margin:0 0 20px; color:#7a7570; font-size:14px;">預約確認</p>
        </td></tr>

        <tr><td style="padding:0 28px 16px;">
          <p style="margin:0 0 16px; font-size:15px;">${escape(b.customer_name)} 您好,您的預約已收到。</p>
          <table role="presentation" width="100%" cellpadding="6" cellspacing="0" style="font-size:14px;">
            <tr><td style="color:#7a7570; width:80px;">編號</td>
                <td><span style="background:#fff3cd; color:#b35900; padding:2px 8px; border-radius:4px; font-weight:700;">${ref}</span></td></tr>
            <tr><td style="color:#7a7570;">時間</td><td><strong>${time}</strong></td></tr>
            <tr><td style="color:#7a7570;">服務</td><td>${escape(b.service_name)} <span style="color:#7a7570;">(${b.duration_minutes} 分 / $${b.service_price})</span></td></tr>
            <tr><td style="color:#7a7570;">設計師</td><td>${escape(b.staff_name)}</td></tr>
          </table>
        </td></tr>

        ${needDeposit ? `
        <tr><td style="padding:0 28px 16px;">
          <div style="background:#fff5e6; border:1px solid #f5b945; border-radius:8px; padding:16px;">
            <p style="margin:0 0 8px; font-weight:600; font-size:15px;">💰 訂金匯款 $${b.deposit_amount}</p>
            <p style="margin:0 0 12px; font-size:13px; color:#7a7570;">請於 24 小時內完成轉帳,逾時系統會自動釋放此時段。</p>
            <table role="presentation" width="100%" cellpadding="4" cellspacing="0" style="font-size:13px;">
              <tr><td style="color:#7a7570; width:60px;">銀行</td><td>${escape(b.tenant_bank_name ?? '—')}</td></tr>
              <tr><td style="color:#7a7570;">帳號</td><td><code style="background:#fff; padding:2px 6px; border-radius:3px;">${escape(b.tenant_bank_account_no ?? '—')}</code></td></tr>
              <tr><td style="color:#7a7570;">戶名</td><td>${escape(b.tenant_bank_account_holder ?? '—')}</td></tr>
              <tr><td style="color:#7a7570;">備註</td><td>請填預約編號 <strong>${ref}</strong></td></tr>
            </table>
            ${b.tenant_bank_transfer_note ? `<p style="margin:8px 0 0; font-size:12px; color:#7a7570;">${escape(b.tenant_bank_transfer_note)}</p>` : ''}
          </div>
        </td></tr>
        ` : `
        <tr><td style="padding:0 28px 16px; font-size:14px; color:#7a7570;">
          本服務無須訂金,請準時到店即可。
        </td></tr>
        `}

        <tr><td style="padding:0 28px 24px;">
          <p style="margin:0 0 8px; font-size:13px; color:#7a7570;">需要改期或取消?</p>
          <a href="${manageUrl}" style="display:inline-block; padding:10px 20px; background:#f5b945; color:#1a1a1a; text-decoration:none; border-radius:6px; border:1px solid #2b2b2b; font-size:14px; font-weight:500;">管理預約</a>
        </td></tr>

        <tr><td style="padding:16px 28px; border-top:1px solid #d9d2bc; background:#f5efd9; font-size:12px; color:#7a7570; text-align:center;">
          ${escape(b.tenant_name)}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`.trim()

  return { subject: `${b.tenant_name} 預約確認 #${ref}`, html, text }
}

// 簡易 HTML escape (避免店家名 / 客人名含 <script> 等)
function escape(s: string | null | undefined): string {
  if (!s) return ''
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

// =============================================================
// 訂金已付 — 老闆按「標訂金已付」時觸發
// =============================================================
export function depositPaidEmail(b: BookingForEmail, siteOrigin: string) {
  const time = fmtTime(b.start_at, b.tenant_timezone)
  const ref = shortRef(b.id)
  const manageUrl = `${siteOrigin}/manage/${b.id}?t=${b.manage_token}`

  const text = [
    `${b.customer_name} 您好,`,
    ``,
    `好消息!您在「${b.tenant_name}」的預約訂金已收到,預約確認:`,
    ``,
    `編號: ${ref}`,
    `時間: ${time}`,
    `服務: ${b.service_name} (${b.duration_minutes} 分)`,
    `設計師: ${b.staff_name}`,
    `訂金: $${b.deposit_amount} (已收訖)`,
    ``,
    `請準時到店。若需改期或取消,使用此連結:`,
    manageUrl,
    ``,
    `${b.tenant_name}`,
  ].join('\n')

  const html = `
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${escape(b.tenant_name)} 訂金已收訖</title></head>
<body style="margin:0; background:#f3eedd; font-family:-apple-system,BlinkMacSystemFont,'PingFang TC',sans-serif; color:#1a1a1a;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3eedd; padding:32px 16px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px; background:#fdfaf1; border:1px solid #2b2b2b; border-radius:14px; overflow:hidden;">
        <tr><td style="padding:24px 28px 8px;">
          <h1 style="margin:0 0 8px; font-family:Georgia,serif; font-weight:400; font-size:24px;">${escape(b.tenant_name)}</h1>
          <p style="margin:0 0 20px; color:#7a7570; font-size:14px;">訂金已收訖 · 預約確認</p>
        </td></tr>

        <tr><td style="padding:0 28px 16px;">
          <div style="background:#e8f5e9; border:1px solid #34c759; border-radius:8px; padding:12px 14px; margin-bottom:16px;">
            <p style="margin:0; font-weight:600; color:#1b5e20;">✓ 已收訂金 $${b.deposit_amount}</p>
          </div>
          <p style="margin:0 0 16px; font-size:15px;">${escape(b.customer_name)} 您好,您的預約已正式確認:</p>
          <table role="presentation" width="100%" cellpadding="6" cellspacing="0" style="font-size:14px;">
            <tr><td style="color:#7a7570; width:80px;">編號</td>
                <td><span style="background:#fff3cd; color:#b35900; padding:2px 8px; border-radius:4px; font-weight:700;">${ref}</span></td></tr>
            <tr><td style="color:#7a7570;">時間</td><td><strong>${time}</strong></td></tr>
            <tr><td style="color:#7a7570;">服務</td><td>${escape(b.service_name)} <span style="color:#7a7570;">(${b.duration_minutes} 分)</span></td></tr>
            <tr><td style="color:#7a7570;">設計師</td><td>${escape(b.staff_name)}</td></tr>
          </table>
        </td></tr>

        <tr><td style="padding:0 28px 24px;">
          <p style="margin:0 0 8px; font-size:13px; color:#7a7570;">需要改期或取消?</p>
          <a href="${manageUrl}" style="display:inline-block; padding:10px 20px; background:#f5b945; color:#1a1a1a; text-decoration:none; border-radius:6px; border:1px solid #2b2b2b; font-size:14px; font-weight:500;">管理預約</a>
        </td></tr>

        <tr><td style="padding:16px 28px; border-top:1px solid #d9d2bc; background:#f5efd9; font-size:12px; color:#7a7570; text-align:center;">
          ${escape(b.tenant_name)}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`.trim()

  return { subject: `${b.tenant_name} 訂金已收訖 #${ref}`, html, text }
}
