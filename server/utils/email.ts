// Resend wrapper.
// Dev mode (沒設 RESEND_API_KEY) → 不真寄,console.log 出來就好,方便本機開發。
// Prod → 走 Resend HTTPS API (不額外裝 sdk, fetch 即可)。

export interface SendEmailInput {
  to: string
  subject: string
  html: string
  text?: string
  /** 從哪個寄件人寄;沒帶用 EMAIL_FROM env */
  from?: string
}

export interface SendEmailResult {
  ok: boolean
  /** 成功時的訊息 id, 失敗時為 null */
  id: string | null
  error?: string
  /** dev mode 沒真寄 */
  simulated?: boolean
}

const RESEND_ENDPOINT = 'https://api.resend.com/emails'

export async function sendEmail(input: SendEmailInput): Promise<SendEmailResult> {
  const key = process.env.RESEND_API_KEY
  const from = input.from ?? process.env.EMAIL_FROM ?? 'onboarding@resend.dev'

  // Dev fallback: 沒設 key → 只 log, 不真寄
  if (!key) {
    console.log('[email:dev]', { to: input.to, from, subject: input.subject })
    console.log('[email:dev]', input.text || input.html.slice(0, 200))
    return { ok: true, id: 'simulated', simulated: true }
  }

  try {
    const res = await $fetch<{ id?: string; message?: string }>(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: {
        from,
        to: [input.to],
        subject: input.subject,
        html: input.html,
        text: input.text,
      },
    })
    if (!res.id) {
      return { ok: false, id: null, error: res.message ?? 'no id returned' }
    }
    return { ok: true, id: res.id }
  } catch (e: any) {
    // $fetch 拋出時 e.data 通常含 Resend 的錯誤訊息
    const msg = e?.data?.message ?? e?.message ?? 'unknown'
    return { ok: false, id: null, error: msg }
  }
}
