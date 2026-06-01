// LINE Messaging API wrapper.
// 文件: https://developers.line.biz/en/reference/messaging-api/
//
// 一個 tenant 一個 channel,token 存 tenants.line_channel_access_token。
// Push API endpoint: POST /v2/bot/message/push (需 user_id + messages)

export interface LineMessage {
  type: 'text'
  text: string
}

export interface PushOptions {
  channelAccessToken: string
  to: string           // LINE user id
  messages: LineMessage[]
}

export interface PushResult {
  ok: boolean
  status?: number
  error?: string
  simulated?: boolean
}

const LINE_ENDPOINT = 'https://api.line.me/v2/bot/message/push'

export async function linePush(opts: PushOptions): Promise<PushResult> {
  if (!opts.channelAccessToken) {
    // Dev mode: 沒設 token → log 而已
    console.log('[line:dev]', { to: opts.to, messages: opts.messages })
    return { ok: true, simulated: true }
  }
  try {
    await $fetch(LINE_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${opts.channelAccessToken}`,
        'Content-Type': 'application/json',
      },
      body: { to: opts.to, messages: opts.messages },
    })
    return { ok: true, status: 200 }
  } catch (e: any) {
    const status = e?.response?.status ?? e?.statusCode
    const msg = e?.data?.message ?? e?.response?._data?.message ?? e?.message ?? 'unknown'
    return { ok: false, status, error: msg }
  }
}
