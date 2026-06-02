<script setup lang="ts">
// 後台 - 店家設定 (目前只有銀行帳號)
// 之後會把 timezone / 名稱 / LINE 設定 等都放這裡。
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

interface TenantSettings {
  name: string
  slug: string
  bank_name: string | null
  bank_account_no: string | null
  bank_account_holder: string | null
  bank_transfer_note: string | null
  points_earn_per_dollar: number
  points_redeem_value: number
}

const form = reactive<TenantSettings>({
  name: '', slug: '',
  bank_name: '', bank_account_no: '', bank_account_holder: '', bank_transfer_note: '',
  points_earn_per_dollar: 0,
  points_redeem_value: 1,
})

const RESERVED_SLUGS = new Set([
  'www','app','admin','api','auth','static','cdn',
  'mail','email','dashboard','docs','help','support',
  'blog','status','localhost',
])
const slugError = ref<string | null>(null)

function validateSlug(s: string): string | null {
  if (s.length < 3 || s.length > 30) return 'slug 需 3–30 字'
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(s)) return '只能小寫字母、數字、連字號;不可開頭/結尾為 -'
  if (RESERVED_SLUGS.has(s)) return '這是保留字,請換一個'
  return null
}

watch(() => form.slug, (v) => { slugError.value = validateSlug(v) })

// 顯示完整 URL (用瀏覽器當前 host 推 root domain)
const fullUrl = computed(() => {
  if (!form.slug || slugError.value) return ''
  if (process.server) return `https://${form.slug}.example.com`
  // 把當前 host 的第一段換成新 slug
  const host = location.host
  const parts = host.split('.')
  if (parts.length >= 3) parts[0] = form.slug
  else parts.unshift(form.slug) // localhost → newslug.localhost (其實不會解析,但顯示給看)
  return `${location.protocol}//${parts.join('.')}`
})
const loading = ref(false)
const saving = ref(false)
const error = ref<string | null>(null)
const okMsg = ref<string | null>(null)

async function load() {
  if (!tenant.value) return
  loading.value = true
  const { data, error: e } = await supabase
    .from('tenants')
    .select('name, slug, bank_name, bank_account_no, bank_account_holder, bank_transfer_note, points_earn_per_dollar, points_redeem_value')
    .eq('id', tenant.value.id)
    .maybeSingle()
  loading.value = false
  if (e) { error.value = e.message; return }
  if (data) Object.assign(form, data)
}
await load()

async function save() {
  if (!tenant.value) return
  if (slugError.value) { error.value = `子網域格式錯誤: ${slugError.value}`; return }
  saving.value = true
  error.value = null
  okMsg.value = null
  const { error: e } = await supabase
    .from('tenants')
    .update({
      name: form.name.trim(),
      slug: form.slug.trim(),
      bank_name: form.bank_name?.trim() || null,
      bank_account_no: form.bank_account_no?.trim() || null,
      bank_account_holder: form.bank_account_holder?.trim() || null,
      bank_transfer_note: form.bank_transfer_note?.trim() || null,
      points_earn_per_dollar: form.points_earn_per_dollar,
      points_redeem_value: form.points_redeem_value,
    })
    .eq('id', tenant.value.id)
  saving.value = false
  if (e) {
    // 23505 = unique_violation (slug 撞名)
    if ((e as any).code === '23505') error.value = '這個子網域已有人使用,請換一個'
    else error.value = e.message
  } else {
    okMsg.value = '已儲存。子網域變更後請使用新網址。'
  }
}

const copied = ref(false)
async function copyUrl() {
  try {
    await navigator.clipboard.writeText(fullUrl.value)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch {}
}

// ---------- LINE 設定 ----------
const lineForm = reactive({
  channel_id: '',
  access_token: '',
  channel_secret: '',
})
const lineStatus = ref<{
  has_channel: boolean; has_token: boolean; has_secret: boolean
  channel_id: string | null; msgs_used_this_month: number
} | null>(null)
const lineSaving = ref(false)
const lineMsg = ref<string | null>(null)

async function loadLineStatus() {
  if (!tenant.value) return
  const { data, error: e } = await supabase.rpc('tenant_line_settings_status', { p_tenant_id: tenant.value.id })
  if (!e) {
    const row = Array.isArray(data) ? data[0] : data
    lineStatus.value = row ?? null
    if (row?.channel_id) lineForm.channel_id = row.channel_id
  }
}
await loadLineStatus()

async function saveLine() {
  if (!tenant.value) return
  lineSaving.value = true
  lineMsg.value = null
  const { error: e } = await supabase.rpc('tenant_line_settings_set', {
    p_tenant_id: tenant.value.id,
    p_channel_id: lineForm.channel_id,
    p_access_token: lineForm.access_token,
    p_channel_secret: lineForm.channel_secret,
  })
  lineSaving.value = false
  if (e) lineMsg.value = e.message
  else {
    lineMsg.value = '已儲存'
    lineForm.access_token = ''
    lineForm.channel_secret = ''
    await loadLineStatus()
  }
}

async function clearLine() {
  if (!confirm('確定移除 LINE 設定?')) return
  if (!tenant.value) return
  await supabase.rpc('tenant_line_settings_set', {
    p_tenant_id: tenant.value.id, p_channel_id: '', p_access_token: '', p_channel_secret: '',
  })
  lineForm.channel_id = ''
  lineForm.access_token = ''
  lineForm.channel_secret = ''
  await loadLineStatus()
}

const webhookUrl = computed(() => {
  if (!lineForm.channel_id || process.server) return ''
  return `${location.origin}/api/webhook/line/${lineForm.channel_id}`
})
</script>

<template>
  <div>
    <h1>店家設定</h1>
    <p v-if="!tenant" class="muted">尚未綁定店家。</p>

    <section v-if="tenant" class="card">
      <h2>基本</h2>
      <label class="field">店家名稱
        <input v-model="form.name" placeholder="如:示範美髮沙龍" />
      </label>

      <label class="field">子網域 slug
        <input v-model="form.slug" placeholder="僅小寫字母 / 數字 / 連字號" />
      </label>
      <p v-if="slugError" class="err">{{ slugError }}</p>
      <div v-else-if="fullUrl" class="url-preview">
        你的預約頁:
        <code>{{ fullUrl }}/book</code>
        <button class="copy-btn" @click="copyUrl">{{ copied ? '已複製 ✓' : '複製' }}</button>
      </div>
    </section>

    <section v-if="tenant" class="card">
      <h2>銀行帳號 (訂金轉帳)</h2>
      <p class="muted small">
        客人預約需收訂金時,系統會在預約成功頁顯示這些資訊。
        平台不經手金流,錢直接匯到你自己的帳戶。
      </p>

      <div class="grid">
        <label class="field">銀行 / 分行
          <input v-model="form.bank_name" placeholder="如:國泰世華 信義分行" />
        </label>
        <label class="field">帳號
          <input v-model="form.bank_account_no" placeholder="如:0123456789" />
        </label>
        <label class="field">戶名
          <input v-model="form.bank_account_holder" placeholder="如:王小明" />
        </label>
      </div>

      <label class="field">轉帳說明 (給客人看)
        <textarea v-model="form.bank_transfer_note" rows="3"
                  placeholder="例如:請於 24 小時內完成轉帳並 LINE 通知我們末五碼,逾時系統將自動釋放時段。" />
      </label>
    </section>

    <section v-if="tenant" class="card">
      <h2>集點卡</h2>
      <p class="muted small">
        設 0 = 關閉集點。例:0.1 表示 $10 消費 = 1 點;1 點 = $1 折抵。
        客人預約「completed」時自動加點 (依實收金額)。
      </p>
      <div class="grid">
        <label class="field">每元賺多少點 (earn rate)
          <input v-model.number="form.points_earn_per_dollar" type="number" min="0" step="0.01"
                 placeholder="0 = 關閉" />
        </label>
        <label class="field">1 點 = 多少元 (redeem value)
          <input v-model.number="form.points_redeem_value" type="number" min="0.01" step="0.5" />
        </label>
      </div>
    </section>

    <section v-if="tenant" class="card">
      <h2>LINE OA 通知</h2>
      <p class="muted small">
        到 <a href="https://developers.line.biz/" target="_blank" rel="noopener">LINE Developers</a> →
        Provider → Messaging API channel → 拿 Channel access token (long-lived) 貼進來。
        客人加你的 OA 為好友後,在會員資料貼上他的 LINE user ID 就能推播。
      </p>

      <div v-if="lineStatus" class="status">
        <span :class="['lg-pill', lineStatus.has_token ? 'ok' : 'warn']">
          {{ lineStatus.has_token ? '✓ 已設定' : '✗ 未設定' }}
        </span>
        <span v-if="lineStatus.has_token" class="muted small">
          本月已用 {{ lineStatus.msgs_used_this_month }} 則
        </span>
      </div>

      <div class="grid">
        <label class="field">Channel ID
          <input v-model="lineForm.channel_id" placeholder="例:1234567890" />
        </label>
        <label class="field">Channel Access Token (long-lived)
          <input v-model="lineForm.access_token" type="password"
                 :placeholder="lineStatus?.has_token ? '已設定,留空維持原值' : '貼入 token'" />
        </label>
        <label class="field">Channel Secret (webhook 驗證用)
          <input v-model="lineForm.channel_secret" type="password"
                 :placeholder="lineStatus?.has_secret ? '已設定,留空維持原值' : '貼入 secret'" />
        </label>
      </div>

      <div v-if="webhookUrl && lineStatus?.has_secret" class="webhook-info">
        <p class="muted small">
          填上面 3 欄後,到 LINE Developers → 該 channel → Messaging API → Webhook URL 設成:
        </p>
        <code class="url">{{ webhookUrl }}</code>
        <p class="muted small">並打開「Use webhook」。客人加你的 OA 為好友後,傳電話即可自動綁定。</p>
      </div>

      <div class="actions-inline">
        <button :disabled="lineSaving" @click="saveLine">{{ lineSaving ? '儲存中…' : '儲存 LINE 設定' }}</button>
        <button v-if="lineStatus?.has_token" class="ghost" @click="clearLine">移除</button>
        <span v-if="lineMsg" class="muted small">{{ lineMsg }}</span>
      </div>
    </section>

    <div class="actions" v-if="tenant">
      <button :disabled="saving" @click="save">{{ saving ? '儲存中…' : '儲存設定' }}</button>
      <span v-if="okMsg" class="ok">{{ okMsg }}</span>
      <span v-if="error" class="err">{{ error }}</span>
    </div>
  </div>
</template>

<style scoped>
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.6rem; }
.muted { color: #888; }
.small { font-size: 0.85rem; }
.field { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; margin-top: 0.7rem; }
.field input, .field textarea { padding: 0.5rem 0.6rem; border: 1px solid #ddd; border-radius: 4px; font: inherit; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 0.7rem; }
.actions { display: flex; gap: 1rem; align-items: center; margin-top: 1rem; }
button { padding: 0.55rem 1rem; border: 1px solid #2b2b2b; border-radius: 4px; background: #f5b945; color: #1a1a1a; cursor: pointer; font-size: 0.95rem; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
.ok { color: #1a7a3a; font-size: 0.9rem; }
.err { color: #c0392b; font-size: 0.9rem; margin: 0.4rem 0 0; }
.url-preview {
  margin-top: 0.5rem; padding: 0.55rem 0.75rem; background: #f7f7f7;
  border-radius: 4px; font-size: 0.88rem; display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap;
}
.url-preview code { background: #fff; padding: 0.2rem 0.4rem; border-radius: 3px; }
.copy-btn { padding: 0.3rem 0.7rem; border: 1px solid #2b2b2b; border-radius: 4px; background: #f5b945; color: #1a1a1a; cursor: pointer; font-size: 0.82rem; }
.status { display: flex; gap: 0.75rem; align-items: center; margin: 0.5rem 0; }
.lg-pill { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
.lg-pill.ok   { background: #e8f5e9; color: #1b5e20; }
.lg-pill.warn { background: #fff5e6; color: #b35900; }
.actions-inline { display: flex; gap: 0.75rem; align-items: center; flex-wrap: wrap; margin-top: 0.5rem; }
.actions-inline .ghost { background: transparent; }
.webhook-info { margin-top: 0.75rem; padding: 0.75rem; background: #fff; border: 1px dashed #d9d2bc; border-radius: 6px; }
.webhook-info .url { display: block; font-size: 0.85rem; padding: 0.4rem 0.6rem; background: #f7f2e3; border-radius: 4px; word-break: break-all; margin: 0.3rem 0; }
</style>
