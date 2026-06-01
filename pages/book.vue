<script setup lang="ts">
// 前台 - 公開預約頁 (anon)
// 流程: 選服務 → 選設計師(或不指定) → 選日期 → 選時段 → 填資料 → 送出
// 所有寫入走 SECURITY DEFINER RPC,不直接寫表 (RLS 已擋)。
definePageMeta({ layout: 'storefront' })

interface Service { id: string; name: string; duration_minutes: number; price: number; deposit_amount: number | null; image_path: string | null; is_addon: boolean }
interface Staff { id: string; name: string; portfolio: string[] }

const supabase = useSupabaseClient()
const user = useSupabaseUser()
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
async function loadBankInfo() {
  if (!tenantBase.value) return
  try {
    const { data, error: e } = await supabase
      .from('tenants')
      .select('bank_name, bank_account_no, bank_account_holder, bank_transfer_note')
      .eq('id', tenantBase.value.id)
      .maybeSingle()
    if (!e && data) bankInfo.value = data as any
  } catch {}
}
loadBankInfo()

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
const mainServices = computed(() => services.value.filter(s => !s.is_addon))
const addonServices = computed(() => services.value.filter(s => s.is_addon))

async function loadServices() {
  if (!tenant.value) return
  const { data } = await supabase
    .from('services')
    .select('id, name, duration_minutes, price, deposit_amount, image_path, is_addon')
    .eq('tenant_id', tenant.value.id)
    .eq('is_active', true)
    .order('name')
  services.value = (data ?? []) as Service[]
}
await loadServices()

// ---------- step 1.5: 加購選擇 (multi) ----------
const selectedAddonIds = ref<Set<string>>(new Set())
function toggleAddon(id: string) {
  if (selectedAddonIds.value.has(id)) selectedAddonIds.value.delete(id)
  else selectedAddonIds.value.add(id)
  selectedAddonIds.value = new Set(selectedAddonIds.value) // 觸發 reactivity
}
// 換主服務時清空 addons
watch(selectedServiceId, () => { selectedAddonIds.value = new Set() })

const totalDuration = computed(() => {
  let n = selectedService.value?.duration_minutes ?? 0
  for (const id of selectedAddonIds.value) {
    const a = addonServices.value.find(s => s.id === id)
    if (a) n += a.duration_minutes
  }
  return n
})
const totalPrice = computed(() => {
  let n = selectedService.value?.price ?? 0
  for (const id of selectedAddonIds.value) {
    const a = addonServices.value.find(s => s.id === id)
    if (a) n += a.price
  }
  return n
})
const totalDeposit = computed(() => {
  let n = selectedService.value?.deposit_amount ?? 0
  for (const id of selectedAddonIds.value) {
    const a = addonServices.value.find(s => s.id === id)
    if (a) n += (a.deposit_amount ?? 0)
  }
  return n
})

// ---------- 優惠碼 ----------
const couponCode = ref('')
const couponState = ref<
  | { state: 'idle' }
  | { state: 'checking' }
  | { state: 'valid'; amount_off: number; final_amount: number; coupon_name: string }
  | { state: 'invalid'; reason: string }
>({ state: 'idle' })

async function validateCoupon() {
  if (!tenantBase.value) return
  const code = couponCode.value.trim()
  if (!code) { couponState.value = { state: 'idle' }; return }
  couponState.value = { state: 'checking' }
  const { data, error: e } = await supabase.rpc('validate_coupon', {
    p_tenant_id: tenantBase.value.id,
    p_code: code,
    p_amount: totalPrice.value,
    p_member_phone: customer.phone || null,
  })
  if (e) { couponState.value = { state: 'invalid', reason: e.message }; return }
  const row = Array.isArray(data) ? data[0] : data
  if (row?.valid) {
    couponState.value = {
      state: 'valid',
      amount_off: Number(row.amount_off),
      final_amount: Number(row.final_amount),
      coupon_name: row.coupon_name,
    }
  } else {
    const msg = ({
      empty_code: '請輸入優惠碼',
      not_found: '找不到此優惠碼',
      min_amount_not_met: '未達最低消費門檻',
      max_uses_reached: '此優惠碼已用罄',
      member_limit_reached: '你已使用過此優惠碼',
    } as any)[row?.reason ?? ''] ?? '無效'
    couponState.value = { state: 'invalid', reason: msg }
  }
}
// 換主服務或加購 → 重新驗證
watch([selectedServiceId, selectedAddonIds], () => {
  if (couponState.value.state === 'valid') validateCoupon()
}, { deep: true })

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

watch([selectedServiceId, selectedStaffId, selectedDate, selectedAddonIds], async ([sid, stf, date, addons]) => {
  selectedSlot.value = null
  slots.value = []
  if (!sid || !stf || !date) return
  slotsLoading.value = true
  const addonArr = Array.from(addons as Set<string>)
  try {
    if (stf === '__any__') {
      const all = await Promise.all(
        eligibleStaff.value.map(s => getAvailableSlots({ staffId: s.id, serviceId: sid as string, date: date as string, addonIds: addonArr })),
      )
      const set = new Set<string>()
      for (const arr of all) for (const t of arr) set.add(t)
      slots.value = Array.from(set).sort()
    } else {
      slots.value = await getAvailableSlots({ staffId: stf as string, serviceId: sid as string, date: date as string, addonIds: addonArr })
    }
  } finally {
    slotsLoading.value = false
  }
}, { deep: true })

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
    addonIds: Array.from(selectedAddonIds.value),
    couponCode: couponState.value.state === 'valid' ? couponCode.value.trim() : undefined,
  })
  if (result) {
    submitted.value = result
    // Fire-and-forget 通知 (email + LINE 並行); 失敗不影響預約已建立
    if (customer.email) {
      $fetch('/api/notify/booking-created', {
        method: 'POST',
        body: {
          bookingId: result.bookingId,
          manageToken: result.manageToken,
          customerEmail: customer.email,
          customerName: customer.name,
        },
      }).catch((err) => console.warn('email notify failed', err))
    }
    // LINE: server route 自己判斷有沒有綁 user_id; 沒綁就 skip
    $fetch('/api/notify/booking-line', {
      method: 'POST',
      body: { bookingId: result.bookingId },
    }).catch((err) => console.warn('line notify failed', err))
  }
}

function reset() {
  submitted.value = null
  selectedServiceId.value = null
  selectedStaffId.value = null
  selectedSlot.value = null
  selectedAddonIds.value = new Set()
  customer.name = ''
  customer.phone = ''
  customer.email = ''
  customer.note = ''
}
</script>

<template>
  <main class="page">
    <header class="head">
      <h1 class="lg-largetitle">{{ tenant?.name ?? '線上預約' }}</h1>
      <p v-if="!tenant" class="lg-callout lg-muted">店家設定中,請稍候。</p>
      <p v-else class="lg-callout lg-muted">線上自助預約</p>
    </header>

    <!-- 成功畫面 -->
    <section v-if="submitted" class="lg-card success">
      <div class="success-head">
        <div class="check-circle">✓</div>
        <h2 class="lg-title2">預約已送出</h2>
        <p class="lg-subhead">
          編號 <code class="ref">{{ shortRef(submitted.bookingId) }}</code>
        </p>
      </div>

      <!-- 需訂金 -->
      <template v-if="totalDeposit > 0">
        <div class="payment glass-tinted">
          <div class="payment-head">
            <span class="lg-headline">訂金匯款</span>
            <span class="lg-pill lg-pill-warning">${{ totalDeposit }}</span>
          </div>
          <p class="lg-footnote">24 小時內完成轉帳,逾時系統將自動釋放此時段。</p>

          <template v-if="tenant?.bank_account_no">
            <dl class="bank">
              <dt>銀行</dt><dd>{{ tenant.bank_name || '—' }}</dd>
              <dt>帳號</dt><dd><code>{{ tenant.bank_account_no }}</code></dd>
              <dt>戶名</dt><dd>{{ tenant.bank_account_holder || '—' }}</dd>
              <dt>備註</dt><dd>填入 <code class="ref">{{ shortRef(submitted.bookingId) }}</code></dd>
            </dl>
            <p v-if="tenant.bank_transfer_note" class="lg-footnote">{{ tenant.bank_transfer_note }}</p>
          </template>
          <p v-else class="lg-footnote">⚠️ 店家尚未設定銀行帳號,請直接聯絡店家。</p>
        </div>
      </template>
      <p v-else class="lg-subhead lg-muted">本服務無須訂金,請準時到店即可。</p>

      <!-- 自助管理連結 -->
      <div class="manage glass-tinted">
        <div class="payment-head">
          <span class="lg-headline">管理你的預約</span>
        </div>
        <p class="lg-footnote">收藏此連結,可隨時改期或取消 (不需登入)</p>
        <div class="manage-link">
          <code>{{ manageUrl(submitted.bookingId, submitted.manageToken) }}</code>
          <button class="lg-btn lg-btn-secondary lg-btn-sm"
                  @click="copyManageLink(manageUrl(submitted.bookingId, submitted.manageToken))">
            {{ copied ? '已複製' : '複製' }}
          </button>
        </div>
        <NuxtLink :to="`/manage/${submitted.bookingId}?t=${submitted.manageToken}`"
                  class="lg-btn lg-btn-filled">前往管理頁</NuxtLink>
      </div>

      <!-- 引導註冊 (沒登入時才顯示) -->
      <div v-if="!user" class="signup-hint glass-tinted">
        <span class="lg-callout">下次想免填資料?</span>
        <NuxtLink :to="`/login?redirect=/my`" class="lg-btn lg-btn-filled lg-btn-sm">建立會員</NuxtLink>
      </div>
      <NuxtLink v-else to="/my" class="lg-btn lg-btn-secondary lg-btn-sm signup-hint">→ 查看我的預約</NuxtLink>

      <button class="lg-btn lg-btn-secondary reset-btn" @click="reset">再約一次</button>
    </section>

    <template v-else-if="tenant">
      <!-- step 1 服務 -->
      <section class="lg-card step">
        <header class="step-head">
          <span class="step-num">1</span>
          <h2 class="lg-title3">選擇服務</h2>
        </header>
        <div class="choices">
          <button v-for="s in mainServices" :key="s.id"
                  class="choice service-choice"
                  :class="{ active: selectedServiceId === s.id }"
                  @click="selectedServiceId = s.id">
            <img v-if="s.image_path" :src="publicUrl(s.image_path)!" :alt="s.name" class="service-img" />
            <div class="service-meta">
              <strong class="lg-headline">{{ s.name }}</strong>
              <span class="lg-footnote">{{ s.duration_minutes }} 分 · ${{ s.price }}</span>
              <span v-if="s.deposit_amount" class="lg-pill lg-pill-warning">需訂金 ${{ s.deposit_amount }}</span>
            </div>
          </button>
        </div>
      </section>

      <!-- step 1.5 加購 -->
      <section v-if="selectedServiceId && addonServices.length" class="lg-card step">
        <header class="step-head">
          <span class="step-num">+</span>
          <h2 class="lg-title3">加購 <span class="lg-subhead lg-muted">(可選)</span></h2>
        </header>
        <div class="addons">
          <label v-for="a in addonServices" :key="a.id" class="addon"
                 :class="{ active: selectedAddonIds.has(a.id) }">
            <input type="checkbox"
                   :checked="selectedAddonIds.has(a.id)"
                   @change="toggleAddon(a.id)" />
            <span class="addon-info">
              <strong class="lg-callout">{{ a.name }}</strong>
              <span class="lg-footnote">+{{ a.duration_minutes }} 分 · +${{ a.price }}</span>
            </span>
          </label>
        </div>
        <div v-if="selectedAddonIds.size > 0" class="total">
          <span class="lg-footnote">總計</span>
          <strong class="lg-headline">{{ totalDuration }} 分 · ${{ totalPrice }}</strong>
          <span v-if="totalDeposit > 0" class="lg-pill lg-pill-warning">訂金 ${{ totalDeposit }}</span>
        </div>
      </section>

      <!-- step 2 設計師 -->
      <section v-if="selectedServiceId" class="lg-card step">
        <header class="step-head">
          <span class="step-num">2</span>
          <h2 class="lg-title3">選擇設計師</h2>
        </header>
        <p v-if="!eligibleStaff.length" class="lg-muted">此服務目前無可預約設計師。</p>
        <div v-else class="choices">
          <button class="choice"
                  :class="{ active: selectedStaffId === '__any__' }"
                  @click="selectedStaffId = '__any__'">
            <strong class="lg-headline">不指定</strong>
            <span class="lg-footnote">系統指派</span>
          </button>
          <button v-for="s in eligibleStaff" :key="s.id"
                  class="choice staff-choice"
                  :class="{ active: selectedStaffId === s.id }"
                  @click="selectedStaffId = s.id">
            <strong class="lg-headline">{{ s.name }}</strong>
            <div v-if="s.portfolio.length" class="staff-thumbs">
              <img v-for="(p, i) in s.portfolio" :key="i" :src="publicUrl(p)!" :alt="s.name + ' 作品'" />
            </div>
          </button>
        </div>
      </section>

      <!-- step 3 日期 + 時段 -->
      <section v-if="selectedStaffId" class="lg-card step">
        <header class="step-head">
          <span class="step-num">3</span>
          <h2 class="lg-title3">選擇日期與時段</h2>
        </header>
        <div class="lg-field date-field">
          <span class="lg-field-label">日期</span>
          <input v-model="selectedDate" type="date" :min="todayStr" class="lg-input" />
        </div>
        <div v-if="slotsLoading" class="lg-muted">查詢中…</div>
        <div v-else-if="!slots.length" class="lg-muted">這天沒有可預約時段,請換一天。</div>
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
      <section v-if="selectedSlot" class="lg-card step">
        <header class="step-head">
          <span class="step-num">4</span>
          <h2 class="lg-title3">填寫聯絡資料</h2>
        </header>
        <form class="contact" @submit.prevent="submit">
          <label class="lg-field">
            <span class="lg-field-label">姓名 *</span>
            <input v-model="customer.name" required class="lg-input" />
          </label>
          <label class="lg-field">
            <span class="lg-field-label">電話 *</span>
            <input v-model="customer.phone" required pattern="[0-9+\-\s]{6,}" class="lg-input" />
          </label>
          <label class="lg-field">
            <span class="lg-field-label">Email</span>
            <input v-model="customer.email" type="email" placeholder="可不填" class="lg-input" />
          </label>
          <label class="lg-field">
            <span class="lg-field-label">備註</span>
            <textarea v-model="customer.note" rows="2" placeholder="特殊需求,可空白" class="lg-textarea" />
          </label>

          <!-- 優惠碼 -->
          <label class="lg-field">
            <span class="lg-field-label">優惠碼 (可空)</span>
            <div class="coupon-row">
              <input v-model="couponCode" placeholder="如:WELCOME100"
                     class="lg-input" @blur="validateCoupon" />
              <button type="button" class="lg-btn lg-btn-secondary lg-btn-sm" @click="validateCoupon">套用</button>
            </div>
            <span v-if="couponState.state === 'checking'" class="lg-footnote lg-muted">驗證中…</span>
            <span v-else-if="couponState.state === 'valid'" class="lg-pill lg-pill-success coupon-msg">
              {{ couponState.coupon_name }} · 折抵 ${{ couponState.amount_off }} → 總計 ${{ couponState.final_amount }}
            </span>
            <span v-else-if="couponState.state === 'invalid'" class="lg-pill lg-pill-danger coupon-msg">
              {{ couponState.reason }}
            </span>
          </label>

          <p v-if="bkError" class="lg-pill lg-pill-danger err-pill">{{ bkError }}</p>

          <button :disabled="bkLoading" type="submit" class="lg-btn lg-btn-filled submit-btn">
            {{ bkLoading ? '送出中…' : '送出預約' }}
          </button>
        </form>
      </section>
    </template>
  </main>
</template>

<style scoped>
.page {
  max-width: 680px; margin: var(--s-6) auto;
  padding: 0 var(--s-4);
  display: flex; flex-direction: column; gap: var(--s-4);
}
.head { text-align: center; padding: var(--s-3) 0; }
.head h1 { margin: 0 0 var(--s-1); }

/* ── Step card ── */
.step { display: flex; flex-direction: column; gap: var(--s-3); }
.step-head { display: flex; align-items: center; gap: var(--s-3); margin: 0; }
.step-head h2 { margin: 0; }
.step-num {
  width: 28px; height: 28px;
  border-radius: 50%;
  background: var(--accent-fill); color: var(--accent);
  display: inline-flex; align-items: center; justify-content: center;
  font-weight: 600; font-size: var(--t-subhead);
}

/* ── Choices ── */
.choices {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(170px, 1fr));
  gap: var(--s-3);
}
.choice {
  display: flex; flex-direction: column; gap: 4px; align-items: flex-start;
  padding: var(--s-3) var(--s-3);
  background: rgba(255, 255, 255, 0.5);
  border: 1px solid var(--border-hairline);
  border-radius: var(--r-card);
  cursor: pointer; text-align: left;
  transition: transform var(--duration-fast) var(--ease-out),
              background var(--duration-fast) var(--ease-out),
              border-color var(--duration-fast) var(--ease-out);
}
.choice:hover { background: rgba(255,255,255,0.75); }
.choice:active { transform: scale(0.97); }
.choice.active {
  background: var(--accent-fill);
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent) inset;
}

/* service card has image */
.service-choice { padding: 0; overflow: hidden; }
.service-img { width: 100%; aspect-ratio: 16/9; object-fit: cover; display: block; }
.service-meta {
  padding: var(--s-3); display: flex; flex-direction: column;
  gap: 4px; align-items: flex-start; width: 100%;
}

.addons { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: var(--s-2); }
.addon {
  display: flex; align-items: center; gap: var(--s-2);
  padding: 12px;
  background: rgba(255, 255, 255, 0.5);
  border: 1px solid var(--border-hairline);
  border-radius: var(--r-card);
  cursor: pointer;
  transition: background var(--duration-fast), border-color var(--duration-fast);
}
.addon:hover { background: rgba(255, 255, 255, 0.8); }
.addon.active { background: var(--accent-fill); border-color: var(--accent); }
.addon input[type="checkbox"] { width: 18px; height: 18px; flex-shrink: 0; accent-color: var(--accent); }
.addon-info { display: flex; flex-direction: column; gap: 2px; }
.total {
  display: flex; align-items: baseline; gap: var(--s-3);
  padding: var(--s-2) var(--s-3);
  background: var(--accent-fill);
  border-radius: var(--r-control);
  margin-top: var(--s-2);
  flex-wrap: wrap;
}

.staff-thumbs { display: flex; gap: 6px; margin-top: var(--s-2); }
.staff-thumbs img {
  width: 36px; height: 36px; object-fit: cover;
  border-radius: 8px; border: 0.5px solid var(--border-hairline);
}

/* ── Slots ── */
.slots {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(80px, 1fr));
  gap: var(--s-2);
}
.slot {
  padding: 10px;
  background: rgba(255, 255, 255, 0.55);
  border: 1px solid var(--border-hairline);
  border-radius: var(--r-control);
  font-size: var(--t-subhead); font-weight: 500;
  color: var(--text-primary);
  cursor: pointer;
  transition: transform var(--duration-fast), background var(--duration-fast);
}
.slot:hover { background: rgba(255,255,255,0.8); }
.slot:active { transform: scale(0.94); }
.slot.active {
  background: var(--accent);
  color: white;
  border-color: var(--accent);
}

/* ── Contact form ── */
.contact { display: flex; flex-direction: column; gap: var(--s-3); }
.date-field { max-width: 280px; }
.submit-btn { padding: 14px; font-size: var(--t-headline); margin-top: var(--s-2); }
.err-pill { align-self: flex-start; }

/* ── Success ── */
.success { padding: var(--s-5); display: flex; flex-direction: column; gap: var(--s-4); }
.success-head { text-align: center; display: flex; flex-direction: column; gap: 6px; align-items: center; }
.success-head h2 { margin: 0; }
.check-circle {
  width: 56px; height: 56px; border-radius: 50%;
  background: var(--success);
  color: white;
  display: flex; align-items: center; justify-content: center;
  font-size: 28px; font-weight: 700;
  box-shadow: 0 8px 24px rgba(52, 199, 89, 0.32);
}

.payment, .manage {
  border-radius: var(--r-card); padding: var(--s-4);
  display: flex; flex-direction: column; gap: var(--s-2);
}
.payment-head {
  display: flex; align-items: center; justify-content: space-between; gap: var(--s-2);
}
.bank {
  display: grid; grid-template-columns: max-content 1fr;
  gap: 6px var(--s-3); margin: 0; font-size: var(--t-subhead);
}
.bank dt { color: var(--text-secondary); }
.bank dd { margin: 0; color: var(--text-primary); }

.manage-link {
  display: flex; gap: var(--s-2); align-items: stretch;
}
.manage-link code {
  flex: 1; padding: 10px 12px;
  background: rgba(120, 120, 128, 0.12);
  border-radius: var(--r-control);
  font-size: 12px; word-break: break-all;
}

.reset-btn { align-self: center; }
.signup-hint {
  display: flex; align-items: center; gap: var(--s-2); justify-content: space-between;
  padding: var(--s-3) var(--s-4);
  border-radius: var(--r-card);
  margin: var(--s-3) 0;
  text-decoration: none;
}
.coupon-row { display: flex; gap: var(--s-2); }
.coupon-row input { flex: 1; }
.coupon-msg { margin-top: 4px; align-self: flex-start; white-space: normal; }

code { background: rgba(120, 120, 128, 0.12); padding: 2px 6px; border-radius: 4px; font-size: 0.92em; }
code.ref {
  background: var(--warning-fill); color: var(--warning);
  font-weight: 700; padding: 2px 8px; font-size: 1em;
}
</style>
