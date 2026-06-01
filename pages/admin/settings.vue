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
}

const form = reactive<TenantSettings>({
  name: '', slug: '',
  bank_name: '', bank_account_no: '', bank_account_holder: '', bank_transfer_note: '',
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
    .select('name, slug, bank_name, bank_account_no, bank_account_holder, bank_transfer_note')
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
</style>
