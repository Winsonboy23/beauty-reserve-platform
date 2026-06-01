<script setup lang="ts">
// 前台 - 客人自助管理預約 (改期 / 取消)
// 透過 URL 上的 token 驗證身分,不需登入。
definePageMeta({ layout: 'storefront' })

const route = useRoute()
const supabase = useSupabaseClient()
const bookingId = route.params.id as string
const token = (route.query.t as string) ?? ''

interface ManageBooking {
  id: string
  start_at: string
  end_at: string
  status: 'pending' | 'confirmed' | 'completed' | 'cancelled' | 'no_show'
  duration_minutes: number
  note: string | null
  deposit_amount: number
  deposit_status: 'none' | 'pending' | 'paid' | 'refunded' | 'forfeited'
  hold_expires_at: string | null
  staff_id: string; staff_name: string
  service_id: string; service_name: string; service_price: number
  tenant_id: string; tenant_name: string; tenant_timezone: string
  tenant_bank_name: string | null
  tenant_bank_account_no: string | null
  tenant_bank_account_holder: string | null
  tenant_bank_transfer_note: string | null
}

const booking = ref<ManageBooking | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)
const mode = ref<'view' | 'reschedule' | 'cancelled' | 'done'>('view')

async function loadBooking() {
  if (!token) { error.value = '連結無效,缺少授權碼。'; loading.value = false; return }
  loading.value = true
  error.value = null
  const { data, error: e } = await supabase.rpc('get_booking_for_manage', {
    p_booking_id: bookingId, p_token: token,
  })
  loading.value = false
  if (e) { error.value = '連結無效或已過期。'; return }
  const row = Array.isArray(data) ? data[0] : data
  if (!row) { error.value = '找不到此預約,連結可能已失效。'; return }
  booking.value = row as ManageBooking
}
await loadBooking()

// ---------- 改期: 取可用時段 ----------
const { getAvailableSlots } = useBooking()
const newDate = ref(new Date().toISOString().slice(0, 10))
const slots = ref<string[]>([])
const slotsLoading = ref(false)
const newSlot = ref<string | null>(null)

async function refreshSlots() {
  if (!booking.value) return
  slotsLoading.value = true
  slots.value = await getAvailableSlots({
    staffId: booking.value.staff_id,
    serviceId: booking.value.service_id,
    date: newDate.value,
  })
  slotsLoading.value = false
}

watch([mode, newDate], async ([m]) => {
  if (m === 'reschedule') {
    newSlot.value = null
    await refreshSlots()
  }
})

const submitting = ref(false)

async function confirmReschedule() {
  if (!newSlot.value) return
  submitting.value = true
  error.value = null
  const { error: e } = await supabase.rpc('reschedule_booking', {
    p_booking_id: bookingId, p_token: token, p_new_start_at: newSlot.value,
  })
  submitting.value = false
  if (e) {
    error.value = mapErr(e.message)
    return
  }
  mode.value = 'view'
  await loadBooking()
}

async function confirmCancel() {
  if (!confirm('確定取消此預約?此動作無法復原。')) return
  submitting.value = true
  error.value = null
  const { error: e } = await supabase.rpc('cancel_booking_by_token', {
    p_booking_id: bookingId, p_token: token,
  })
  submitting.value = false
  if (e) { error.value = mapErr(e.message); return }
  mode.value = 'cancelled'
  await loadBooking()
}

function mapErr(msg: string) {
  if (msg.includes('slot_taken')) return '這個時段剛被預約走了,請換一個時間。'
  if (msg.includes('slot_unavailable')) return '這個時段目前無法預約。'
  if (msg.includes('booking_not_modifiable')) return '此預約已不可修改 (已完成 / 已取消)。'
  if (msg.includes('booking_not_found')) return '找不到此預約。'
  return '操作失敗,請稍後再試。'
}

function fmt(iso: string) {
  return new Date(iso).toLocaleString('zh-TW', {
    timeZone: booking.value?.tenant_timezone ?? 'Asia/Taipei',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
function fmtTimeOnly(iso: string) {
  return new Date(iso).toLocaleTimeString('zh-TW', {
    timeZone: booking.value?.tenant_timezone ?? 'Asia/Taipei',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
const todayStr = new Date().toISOString().slice(0, 10)
const isPast = computed(() => booking.value && new Date(booking.value.start_at) < new Date())
const isModifiable = computed(() => booking.value && !['cancelled', 'completed', 'no_show'].includes(booking.value.status) && !isPast.value)
</script>

<template>
  <main class="page">
    <p v-if="loading" class="muted">載入中…</p>

    <section v-else-if="error" class="card err-card">
      <h1>無法載入</h1>
      <p>{{ error }}</p>
    </section>

    <template v-else-if="booking">
      <header class="head">
        <h1>{{ booking.tenant_name }}</h1>
        <p class="muted">預約管理</p>
      </header>

      <!-- 預約資訊 -->
      <section class="card">
        <h2>你的預約</h2>
        <dl class="info">
          <dt>時間</dt><dd><strong>{{ fmt(booking.start_at) }}</strong> – {{ fmtTimeOnly(booking.end_at) }}</dd>
          <dt>服務</dt><dd>{{ booking.service_name }} <span class="muted">({{ booking.duration_minutes }} 分 / ${{ booking.service_price }})</span></dd>
          <dt>設計師</dt><dd>{{ booking.staff_name }}</dd>
          <dt>狀態</dt><dd>
            <span :class="['badge', 'b-' + booking.status]">
              {{ ({ pending: '待確認', confirmed: '已確認', completed: '已完成', cancelled: '已取消', no_show: '爽約' } as any)[booking.status] }}
            </span>
          </dd>
          <dt v-if="booking.deposit_status !== 'none'">訂金</dt>
          <dd v-if="booking.deposit_status !== 'none'">
            ${{ booking.deposit_amount }}
            <span :class="['badge', 'd-' + booking.deposit_status]">
              {{ ({ paid: '已付', pending: '待付', refunded: '已退', forfeited: '沒收' } as any)[booking.deposit_status] }}
            </span>
          </dd>
        </dl>

        <!-- 待付訂金 → 顯示銀行帳號 -->
        <div v-if="booking.deposit_status === 'pending' && booking.tenant_bank_account_no" class="payment">
          <h3>💰 訂金匯款</h3>
          <dl class="bank">
            <dt>銀行</dt><dd>{{ booking.tenant_bank_name || '—' }}</dd>
            <dt>帳號</dt><dd><code>{{ booking.tenant_bank_account_no }}</code></dd>
            <dt>戶名</dt><dd>{{ booking.tenant_bank_account_holder || '—' }}</dd>
            <dt>備註</dt><dd>請填預約編號 <code class="ref">{{ booking.id.slice(0, 6).toUpperCase() }}</code></dd>
          </dl>
          <p v-if="booking.tenant_bank_transfer_note" class="muted small">{{ booking.tenant_bank_transfer_note }}</p>
        </div>
      </section>

      <!-- 動作: view 模式 -->
      <section v-if="mode === 'view'" class="card">
        <h2>需要調整?</h2>
        <p v-if="isPast" class="muted">此預約已過時間,無法再修改。</p>
        <p v-else-if="!isModifiable" class="muted">此預約已不可修改。</p>
        <div v-else class="action-row">
          <button @click="mode = 'reschedule'">改期</button>
          <button class="danger" @click="confirmCancel" :disabled="submitting">取消預約</button>
        </div>
      </section>

      <!-- 動作: reschedule 模式 -->
      <section v-if="mode === 'reschedule'" class="card">
        <h2>選擇新時段</h2>
        <p class="muted small">服務時長 {{ booking.duration_minutes }} 分,設計師 {{ booking.staff_name }}</p>
        <label class="field">日期
          <input v-model="newDate" type="date" :min="todayStr" />
        </label>

        <div v-if="slotsLoading" class="muted">查詢中…</div>
        <div v-else-if="!slots.length" class="muted">這天沒有可預約時段。</div>
        <div v-else class="slots">
          <button v-for="t in slots" :key="t"
                  class="slot"
                  :class="{ active: newSlot === t }"
                  @click="newSlot = t">
            {{ fmtTimeOnly(t) }}
          </button>
        </div>

        <div class="action-row">
          <button :disabled="!newSlot || submitting" @click="confirmReschedule">
            {{ submitting ? '處理中…' : '確認改到此時段' }}
          </button>
          <button class="ghost" @click="mode = 'view'">取消</button>
        </div>
      </section>

      <p v-if="error" class="err">{{ error }}</p>
    </template>
  </main>
</template>

<style scoped>
.page { max-width: 640px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui; line-height: 1.5; }
.head h1 { margin: 0 0 0.3rem; }
.muted { color: #888; font-size: 0.92rem; }
.small { font-size: 0.85rem; }
.card { background: #fff; padding: 1.1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; color: #333; }
.err-card { border-color: #f5c2c0; background: #fdf3f2; }
.info { display: grid; grid-template-columns: max-content 1fr; gap: 0.45rem 1rem; margin: 0; }
.info dt { color: #888; font-size: 0.9rem; }
.info dd { margin: 0; font-size: 0.95rem; }
.badge { display: inline-block; font-size: 0.75rem; padding: 0.05rem 0.45rem; border-radius: 4px; background: #eee; margin-left: 0.3rem; }
.b-pending   { background: #fff5e6; color: #b35900; }
.b-confirmed { background: #e3f2fd; color: #0d47a1; }
.b-completed { background: #e8f5e9; color: #1b5e20; }
.b-cancelled { background: #f5f5f5; color: #777; }
.b-no_show   { background: #fce4ec; color: #880e4f; }
.d-paid    { background: #e8f5e9; color: #1b5e20; }
.d-pending { background: #fff5e6; color: #b35900; }
.action-row { display: flex; gap: 0.6rem; margin-top: 0.8rem; flex-wrap: wrap; }
button { padding: 0.55rem 1.1rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.95rem; }
button.ghost { background: #f4f4f4; color: #1a1a1a; }
button.danger { background: #c0392b; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
.field { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; margin: 0.5rem 0; }
.field input { padding: 0.45rem 0.6rem; border: 1px solid #ddd; border-radius: 4px; }
.slots { display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 0.5rem; margin-top: 0.7rem; }
.slot { padding: 0.5rem; border: 1px solid #ddd; border-radius: 4px; background: #fff; color: #1a1a1a; }
.slot.active { background: #1a1a1a; color: #fff; }
.err { color: #c0392b; font-size: 0.9rem; }
.payment { background: #fff8e1; border-radius: 6px; padding: 0.9rem 1.1rem; margin-top: 1rem; }
.payment h3 { font-size: 0.95rem; margin: 0 0 0.5rem; }
.bank { display: grid; grid-template-columns: max-content 1fr; gap: 0.3rem 0.9rem; margin: 0; font-size: 0.92rem; }
.bank dt { color: #888; }
.bank dd { margin: 0; }
code { background: #f4f4f4; padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.85em; }
code.ref { font-size: 0.95rem; font-weight: 600; color: #b35900; background: #fff3cd; padding: 0.15rem 0.5rem; }
</style>
