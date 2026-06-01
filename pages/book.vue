<script setup lang="ts">
// 前台 - 公開預約頁 (anon)
// 流程: 選服務 → 選設計師(或不指定) → 選日期 → 選時段 → 填資料 → 送出
// 所有寫入走 SECURITY DEFINER RPC,不直接寫表 (RLS 已擋)。
definePageMeta({ layout: 'storefront' })

interface Service { id: string; name: string; duration_minutes: number; price: number; deposit_amount: number | null; image_path: string | null }
interface Staff { id: string; name: string; portfolio: string[] }

const supabase = useSupabaseClient()
const tenantBase = useState<{
  id: string; name: string; slug: string; timezone: string
} | null>('tenant')

// tenant 主體只含 core, bank 欄位在這頁 lazy load (避免 middleware 撞到 0004 沒跑)
const bankInfo = ref<{
  bank_name: string | null; bank_account_no: string | null
  bank_account_holder: string | null; bank_transfer_note: string | null
} | null>(null)

const tenant = computed(() => tenantBase.value && bankInfo.value
  ? { ...tenantBase.value, ...bankInfo.value }
  : tenantBase.value)
const { getAvailableSlots, createBooking, loading: bkLoading, error: bkError } = useBooking()
const { publicUrl } = usePortfolio()

useSeoMeta({
  title: () => tenant.value ? `${tenant.value.name} · 線上預約` : '線上預約',
  description: () => tenant.value
    ? `預約 ${tenant.value.name} 的服務。選擇服務、設計師與時段，立即完成預約。`
    : '線上自助預約。',
  ogType: 'website',
})

// 找不到 tenant: 子網域不存在 → 404
if (!tenantBase.value) {
  throw createError({
    statusCode: 404,
    statusMessage: '找不到這家店',
    data: { hint: '請檢查網址是否正確,或聯絡店家確認預約頁網址。' },
    fatal: true,
  })
}

// Lazy-load bank info (0004 可能還沒跑,失敗就靜默)
;(async () => {
  if (!tenantBase.value) return
  const { data } = await supabase
    .from('tenants')
    .select('bank_name, bank_account_no, bank_account_holder, bank_transfer_note')
    .eq('id', tenantBase.value.id)
    .maybeSingle()
    .throwOnError() as any
  if (data) bankInfo.value = data
})().catch(() => { /* 0004 沒跑,沒事,訂金那塊就顯示「請聯絡店家」 */ })

// 短編號 (給客人轉帳備註用): 取 UUID 前 6 碼大寫,易於人類識讀
function shortRef(id: string) { return id.slice(0, 6).toUpperCase() }

function manageUrl(bookingId: string, token: string) {
  if (process.server) return `/manage/${bookingId}?t=${token}`
  return `${location.origin}/manage/${bookingId}?t=${token}`
}

const copied = ref(false)
async function copyManageLink(url: string) {
  try {
    await navigator.clipboard.writeText(url)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch {}
}

// ---------- step 1: 載入服務 ----------
const services = ref<Service[]>([])
const selectedServiceId = ref<string | null>(null)
const selectedService = computed(() => services.value.find(s => s.id === selectedServiceId.value) ?? null)

async function loadServices() {
  if (!tenant.value) return
  const { data } = await supabase
    .from('services')
    .select('id, name, duration_minutes, price, deposit_amount, image_path')
    .eq('tenant_id', tenant.value.id)
    .eq('is_active', true)
    .order('name')
  services.value = (data ?? []) as Service[]
}
await loadServices()

// ---------- step 2: 載入該服務可做的設計師 ----------
const eligibleStaff = ref<Staff[]>([])
// null = 還沒選; '__any__' = 不指定; 否則 staff.id
const selectedStaffId = ref<string | null>(null)

watch(selectedServiceId, async (sid) => {
  selectedStaffId.value = null
  eligibleStaff.value = []
  if (!sid || !tenant.value) return
  // staff_services join staff,取啟用 + 能做此服務的設計師
  const { data } = await supabase
    .from('staff_services')
    .select('staff:staff_id(id, name, is_active, tenant_id)')
    .eq('service_id', sid)
  const list = (data ?? [])
    .map((r: any) => r.staff)
    .filter((s: any) => s && s.is_active && s.tenant_id === tenant.value!.id)

  // 拉每位設計師的前 3 張作品縮圖
  if (list.length) {
    const { data: pf } = await supabase
      .from('staff_portfolio')
      .select('staff_id, storage_path, sort_order')
      .in('staff_id', list.map((s: any) => s.id))
      .order('sort_order')
    const byStaff = new Map<string, string[]>()
    for (const row of (pf ?? []) as any[]) {
      const arr = byStaff.get(row.staff_id) ?? []
      if (arr.length < 3) arr.push(row.storage_path)
      byStaff.set(row.staff_id, arr)
    }
    eligibleStaff.value = list.map((s: any) => ({ id: s.id, name: s.name, portfolio: byStaff.get(s.id) ?? [] }))
  }
})

// ---------- step 3: 日期 → 取可用時段 ----------
const todayStr = new Date().toISOString().slice(0, 10)
const selectedDate = ref(todayStr)
const slots = ref<string[]>([])
const slotsLoading = ref(false)
const selectedSlot = ref<string | null>(null)

watch([selectedServiceId, selectedStaffId, selectedDate], async ([sid, stf, date]) => {
  selectedSlot.value = null
  slots.value = []
  if (!sid || !stf || !date) return
  slotsLoading.value = true
  try {
    if (stf === '__any__') {
      // 不指定設計師 → 把所有可選設計師的時段聯集後去重
      const all = await Promise.all(
        eligibleStaff.value.map(s => getAvailableSlots({ staffId: s.id, serviceId: sid, date })),
      )
      const set = new Set<string>()
      for (const arr of all) for (const t of arr) set.add(t)
      slots.value = Array.from(set).sort()
    } else {
      slots.value = await getAvailableSlots({ staffId: stf, serviceId: sid, date })
    }
  } finally {
    slotsLoading.value = false
  }
})

function fmtSlot(iso: string) {
  // 轉成店家當地時區的 HH:mm
  const d = new Date(iso)
  return d.toLocaleTimeString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}

// ---------- step 4: 填資料 + 送出 ----------
const customer = reactive({ name: '', phone: '', email: '', note: '' })
const submitted = ref<{ bookingId: string; staffId: string | null } | null>(null)

async function submit() {
  if (!tenant.value || !selectedServiceId.value || !selectedSlot.value) return
  const useAny = selectedStaffId.value === '__any__'
  const result = await createBooking({
    tenantId: tenant.value.id,
    serviceId: selectedServiceId.value,
    startAt: selectedSlot.value,
    customerName: customer.name,
    customerPhone: customer.phone,
    customerEmail: customer.email || null,
    note: customer.note || null,
    staffId: useAny ? undefined : selectedStaffId.value!,
  })
  if (result) submitted.value = result
}

function reset() {
  submitted.value = null
  selectedServiceId.value = null
  selectedStaffId.value = null
  selectedSlot.value = null
  customer.name = ''
  customer.phone = ''
  customer.email = ''
  customer.note = ''
}
</script>

<template>
  <main class="page">
    <header class="head">
      <h1>{{ tenant?.name ?? '線上預約' }}</h1>
      <p v-if="!tenant" class="muted">店家設定中,請稍候。</p>
    </header>

    <!-- 成功畫面 -->
    <section v-if="submitted" class="card success">
      <h2>✅ 預約已送出</h2>
      <p>
        預約編號: <code class="ref">{{ shortRef(submitted.bookingId) }}</code>
        <span class="muted small">(完整 ID: {{ submitted.bookingId }})</span>
      </p>

      <!-- 需訂金: 顯示銀行帳號 + 轉帳備註 -->
      <template v-if="selectedService?.deposit_amount">
        <div class="payment">
          <h3>💰 訂金匯款資訊</h3>
          <p>本服務需收訂金 <strong>${{ selectedService.deposit_amount }}</strong>,請於 24 小時內完成轉帳,逾時系統會自動釋放此時段。</p>

          <template v-if="tenant?.bank_account_no">
            <dl class="bank">
              <dt>銀行</dt><dd>{{ tenant.bank_name || '—' }}</dd>
              <dt>帳號</dt><dd><code>{{ tenant.bank_account_no }}</code></dd>
              <dt>戶名</dt><dd>{{ tenant.bank_account_holder || '—' }}</dd>
              <dt>轉帳備註</dt><dd>請填入預約編號 <code class="ref">{{ shortRef(submitted.bookingId) }}</code></dd>
            </dl>
            <p v-if="tenant.bank_transfer_note" class="muted small">{{ tenant.bank_transfer_note }}</p>
          </template>
          <p v-else class="warn">
            ⚠️ 店家尚未設定銀行帳號,請直接聯絡店家確認付款方式。
          </p>
        </div>
      </template>

      <!-- 不需訂金 -->
      <p v-else class="muted">
        本服務無須訂金,請準時到店即可。
      </p>

      <!-- 自助管理連結 -->
      <div class="manage">
        <h3>📅 管理你的預約</h3>
        <p class="muted small">收藏此連結,可隨時改期或取消(不需登入):</p>
        <div class="manage-link">
          <code>{{ manageUrl(submitted.bookingId, submitted.manageToken) }}</code>
          <button class="copy" @click="copyManageLink(manageUrl(submitted.bookingId, submitted.manageToken))">
            {{ copied ? '已複製 ✓' : '複製' }}
          </button>
        </div>
        <p>
          <NuxtLink :to="`/manage/${submitted.bookingId}?t=${submitted.manageToken}`">→ 直接前往管理頁</NuxtLink>
        </p>
      </div>

      <button @click="reset">再約一次</button>
    </section>

    <template v-else-if="tenant">
      <!-- step 1 服務 -->
      <section class="card">
        <h2>1. 選擇服務</h2>
        <div class="choices">
          <button v-for="s in services" :key="s.id"
                  class="choice service-choice"
                  :class="{ active: selectedServiceId === s.id }"
                  @click="selectedServiceId = s.id">
            <img v-if="s.image_path" :src="publicUrl(s.image_path)!" :alt="s.name" class="service-img" />
            <div class="service-meta">
              <strong>{{ s.name }}</strong>
              <span class="muted">{{ s.duration_minutes }} 分 · ${{ s.price }}</span>
              <span v-if="s.deposit_amount" class="tag">需訂金 ${{ s.deposit_amount }}</span>
            </div>
          </button>
        </div>
      </section>

      <!-- step 2 設計師 -->
      <section v-if="selectedServiceId" class="card">
        <h2>2. 選擇設計師</h2>
        <p v-if="!eligibleStaff.length" class="muted">此服務目前無可預約設計師。</p>
        <div v-else class="choices">
          <button class="choice"
                  :class="{ active: selectedStaffId === '__any__' }"
                  @click="selectedStaffId = '__any__'">
            <strong>不指定</strong>
            <span class="muted">由系統指派最快有空的</span>
          </button>
          <button v-for="s in eligibleStaff" :key="s.id"
                  class="choice staff-choice"
                  :class="{ active: selectedStaffId === s.id }"
                  @click="selectedStaffId = s.id">
            <strong>{{ s.name }}</strong>
            <div v-if="s.portfolio.length" class="staff-thumbs">
              <img v-for="(p, i) in s.portfolio" :key="i" :src="publicUrl(p)!" :alt="s.name + ' 作品'" />
            </div>
          </button>
        </div>
      </section>

      <!-- step 3 日期 + 時段 -->
      <section v-if="selectedStaffId" class="card">
        <h2>3. 選擇日期與時段</h2>
        <label>日期
          <input v-model="selectedDate" type="date" :min="todayStr" />
        </label>
        <div v-if="slotsLoading" class="muted">查詢中…</div>
        <div v-else-if="!slots.length" class="muted">這天沒有可預約時段,請換一天。</div>
        <div v-else class="slots">
          <button v-for="t in slots" :key="t"
                  class="slot"
                  :class="{ active: selectedSlot === t }"
                  @click="selectedSlot = t">
            {{ fmtSlot(t) }}
          </button>
        </div>
      </section>

      <!-- step 4 填資料 -->
      <section v-if="selectedSlot" class="card">
        <h2>4. 填寫聯絡資料</h2>
        <form class="contact" @submit.prevent="submit">
          <label>姓名 *<input v-model="customer.name" required /></label>
          <label>電話 *<input v-model="customer.phone" required pattern="[0-9+\-\s]{6,}" /></label>
          <label>Email<input v-model="customer.email" type="email" placeholder="可不填" /></label>
          <label>備註<textarea v-model="customer.note" rows="2" placeholder="特殊需求,可空白" /></label>

          <p v-if="bkError" class="err">{{ bkError }}</p>

          <button :disabled="bkLoading" type="submit" class="primary">
            {{ bkLoading ? '送出中…' : '送出預約' }}
          </button>
        </form>
      </section>
    </template>
  </main>
</template>

<style scoped>
.page { max-width: 640px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui; line-height: 1.5; }
.head h1 { margin: 0 0 0.5rem; }
.muted { color: #888; font-size: 0.9rem; }
.tag { display: inline-block; background: #fff5e6; color: #b35900; padding: 0.05rem 0.4rem; border-radius: 4px; font-size: 0.75rem; margin-left: 0.4rem; }
.warn { background: #fff8e1; padding: 0.6rem 0.8rem; border-radius: 6px; color: #8a6d00; }
.card { background: #fff; padding: 1.1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; color: #333; }
.choices { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 0.6rem; }
.choice {
  display: flex; flex-direction: column; gap: 0.2rem; align-items: flex-start;
  padding: 0.8rem 0.9rem; border: 1px solid #ddd; border-radius: 6px;
  background: #fff; cursor: pointer; text-align: left; font: inherit;
}
.choice.active { border-color: #1a1a1a; box-shadow: 0 0 0 2px #1a1a1a inset; }
.service-choice { padding: 0; overflow: hidden; }
.service-img { width: 100%; aspect-ratio: 16/9; object-fit: cover; display: block; }
.service-meta { padding: 0.7rem 0.85rem; display: flex; flex-direction: column; gap: 0.2rem; align-items: flex-start; }
.staff-thumbs { display: flex; gap: 0.3rem; margin-top: 0.5rem; }
.staff-thumbs img { width: 38px; height: 38px; object-fit: cover; border-radius: 4px; border: 1px solid #eee; }
.slots { display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 0.5rem; margin-top: 0.7rem; }
.slot { padding: 0.5rem; border: 1px solid #ddd; border-radius: 4px; background: #fff; cursor: pointer; font: inherit; }
.slot.active { border-color: #1a1a1a; background: #1a1a1a; color: #fff; }
.contact { display: flex; flex-direction: column; gap: 0.7rem; }
.contact label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; }
.contact input, .contact textarea { padding: 0.5rem 0.65rem; border: 1px solid #ddd; border-radius: 4px; font: inherit; }
button.primary { background: #1a1a1a; color: #fff; padding: 0.7rem; border: 0; border-radius: 4px; font-size: 1rem; cursor: pointer; }
button.primary:disabled { opacity: 0.6; cursor: not-allowed; }
.success { border-color: #c8e6c9; background: #f1f8f4; }
.success h2 { color: #1b5e20; }
.err { color: #c0392b; font-size: 0.9rem; }
code { background: #f4f4f4; padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.85em; }
code.ref { font-size: 1rem; font-weight: 600; color: #b35900; background: #fff3cd; padding: 0.15rem 0.5rem; }
label > input[type="date"] { margin-left: 0.5rem; }
.payment { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 0.9rem 1.1rem; margin: 1rem 0; }
.payment h3 { font-size: 0.95rem; margin: 0 0 0.5rem; }
.bank { display: grid; grid-template-columns: max-content 1fr; gap: 0.3rem 0.9rem; margin: 0.6rem 0; font-size: 0.92rem; }
.bank dt { color: #888; }
.bank dd { margin: 0; }
.manage { margin: 1rem 0; padding: 0.9rem 1.1rem; border: 1px dashed #c8e6c9; border-radius: 6px; background: #fff; }
.manage h3 { font-size: 0.95rem; margin: 0 0 0.4rem; }
.manage-link { display: flex; gap: 0.5rem; align-items: stretch; margin: 0.5rem 0; }
.manage-link code { flex: 1; padding: 0.5rem 0.7rem; background: #f4f4f4; border-radius: 4px; font-size: 0.78rem; word-break: break-all; }
.copy { padding: 0 1rem; background: #1a1a1a; color: #fff; border: 0; border-radius: 4px; cursor: pointer; font-size: 0.85rem; }
</style>
