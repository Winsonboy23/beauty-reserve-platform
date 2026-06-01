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
    <p v-if="loading" class="lg-muted">載入中…</p>

    <section v-else-if="error" class="lg-card err-card">
      <h1 class="lg-title2">無法載入</h1>
      <p class="lg-subhead">{{ error }}</p>
    </section>

    <template v-else-if="booking">
      <header class="head">
        <h1 class="lg-largetitle">{{ booking.tenant_name }}</h1>
        <p class="lg-callout lg-muted">預約管理</p>
      </header>

      <section class="lg-card">
        <h2 class="lg-section-title">你的預約</h2>
        <dl class="info">
          <dt>時間</dt><dd><strong>{{ fmt(booking.start_at) }}</strong> <span class="lg-muted">– {{ fmtTimeOnly(booking.end_at) }}</span></dd>
          <dt>服務</dt><dd>{{ booking.service_name }} <span class="lg-muted">({{ booking.duration_minutes }} 分 / ${{ booking.service_price }})</span></dd>
          <dt>設計師</dt><dd>{{ booking.staff_name }}</dd>
          <dt>狀態</dt>
          <dd>
            <span :class="['lg-pill', 'b-' + booking.status]">
              {{ ({ pending: '待確認', confirmed: '已確認', completed: '已完成', cancelled: '已取消', no_show: '爽約' } as any)[booking.status] }}
            </span>
          </dd>
          <template v-if="booking.deposit_status !== 'none'">
            <dt>訂金</dt>
            <dd>
              ${{ booking.deposit_amount }}
              <span :class="['lg-pill', 'd-' + booking.deposit_status]">
                {{ ({ paid: '已付', pending: '待付', refunded: '已退', forfeited: '沒收' } as any)[booking.deposit_status] }}
              </span>
            </dd>
          </template>
        </dl>

        <div v-if="booking.deposit_status === 'pending' && booking.tenant_bank_account_no" class="payment glass-tinted">
          <span class="lg-headline">訂金匯款</span>
          <dl class="bank">
            <dt>銀行</dt><dd>{{ booking.tenant_bank_name || '—' }}</dd>
            <dt>帳號</dt><dd><code>{{ booking.tenant_bank_account_no }}</code></dd>
            <dt>戶名</dt><dd>{{ booking.tenant_bank_account_holder || '—' }}</dd>
            <dt>備註</dt><dd>填 <code class="ref">{{ booking.id.slice(0, 6).toUpperCase() }}</code></dd>
          </dl>
          <p v-if="booking.tenant_bank_transfer_note" class="lg-footnote">{{ booking.tenant_bank_transfer_note }}</p>
        </div>
      </section>

      <section v-if="mode === 'view'" class="lg-card">
        <h2 class="lg-section-title">需要調整?</h2>
        <p v-if="isPast" class="lg-muted">此預約已過時間,無法再修改。</p>
        <p v-else-if="!isModifiable" class="lg-muted">此預約已不可修改。</p>
        <div v-else class="action-row">
          <button class="lg-btn lg-btn-filled" @click="mode = 'reschedule'">改期</button>
          <button class="lg-btn lg-btn-danger" @click="confirmCancel" :disabled="submitting">取消預約</button>
        </div>
      </section>

      <section v-if="mode === 'reschedule'" class="lg-card">
        <h2 class="lg-section-title">選擇新時段</h2>
        <p class="lg-footnote">服務時長 {{ booking.duration_minutes }} 分,設計師 {{ booking.staff_name }}</p>
        <label class="lg-field date-field">
          <span class="lg-field-label">日期</span>
          <input v-model="newDate" type="date" :min="todayStr" class="lg-input" />
        </label>

        <div v-if="slotsLoading" class="lg-muted">查詢中…</div>
        <div v-else-if="!slots.length" class="lg-muted">這天沒有可預約時段。</div>
        <div v-else class="slots">
          <button v-for="t in slots" :key="t"
                  class="slot"
                  :class="{ active: newSlot === t }"
                  @click="newSlot = t">
            {{ fmtTimeOnly(t) }}
          </button>
        </div>

        <div class="action-row">
          <button class="lg-btn lg-btn-filled" :disabled="!newSlot || submitting" @click="confirmReschedule">
            {{ submitting ? '處理中…' : '確認改到此時段' }}
          </button>
          <button class="lg-btn lg-btn-secondary" @click="mode = 'view'">返回</button>
        </div>
      </section>

      <p v-if="error" class="lg-pill lg-pill-danger err-pill">{{ error }}</p>
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
.err-card { background: var(--danger-fill); }
.info {
  display: grid; grid-template-columns: max-content 1fr;
  gap: var(--s-2) var(--s-4); margin: 0;
}
.info dt { color: var(--text-secondary); font-size: var(--t-footnote); padding-top: 3px; }
.info dd { margin: 0; font-size: var(--t-callout); display: flex; gap: var(--s-2); align-items: center; flex-wrap: wrap; }
.b-pending   { background: var(--warning-fill); color: var(--warning); }
.b-confirmed { background: var(--accent-fill); color: var(--accent); }
.b-completed { background: var(--success-fill); color: var(--success); }
.b-cancelled { background: rgba(120,120,128,0.16); color: var(--text-secondary); }
.b-no_show   { background: var(--danger-fill); color: var(--danger); }
.d-paid    { background: var(--success-fill); color: var(--success); }
.d-pending { background: var(--warning-fill); color: var(--warning); }

.payment {
  margin-top: var(--s-4); padding: var(--s-4);
  border-radius: var(--r-card);
  display: flex; flex-direction: column; gap: var(--s-2);
}
.bank {
  display: grid; grid-template-columns: max-content 1fr;
  gap: 6px var(--s-3); margin: 0; font-size: var(--t-subhead);
}
.bank dt { color: var(--text-secondary); }
.bank dd { margin: 0; }
code { background: rgba(120,120,128,0.12); padding: 2px 6px; border-radius: 4px; font-size: 0.92em; }
code.ref { background: var(--warning-fill); color: var(--warning); font-weight: 700; }

.action-row { display: flex; gap: var(--s-2); margin-top: var(--s-3); flex-wrap: wrap; }
.date-field { max-width: 280px; margin: var(--s-3) 0; }

.slots {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(80px, 1fr));
  gap: var(--s-2); margin-top: var(--s-3);
}
.slot {
  padding: 10px;
  background: rgba(255, 255, 255, 0.55);
  border: 1px solid var(--border-hairline);
  border-radius: var(--r-control);
  color: var(--text-primary);
  font-size: var(--t-subhead); font-weight: 500;
  cursor: pointer;
  transition: background var(--duration-fast), transform var(--duration-fast);
}
.slot:hover { background: rgba(255,255,255,0.8); }
.slot:active { transform: scale(0.94); }
.slot.active { background: var(--accent); color: white; border-color: var(--accent); }

.err-pill { align-self: flex-start; }
</style>
