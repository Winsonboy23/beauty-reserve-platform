<script setup lang="ts">
// 後台 - 月視圖日曆 (按規格實作)
// 樣式: 米白底, 圓角方塊, 月份名垂直襯線, 高亮 = 當月 + 有事件
// 事件文字 (title / time) 在鄰月也顯示但淡化
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

interface Booking {
  id: string
  start_at: string
  end_at: string
  duration_minutes: number
  status: 'pending' | 'confirmed' | 'completed' | 'cancelled' | 'no_show'
  deposit_amount: number
  deposit_status: 'none' | 'pending' | 'paid' | 'refunded' | 'forfeited'
  hold_expires_at: string | null
  note: string | null
  staff: { id: string; name: string } | null
  service: { id: string; name: string } | null
  member: { id: string; name: string; phone: string } | null
}

const now = new Date()
const viewYear = ref(now.getFullYear())
const viewMonth = ref(now.getMonth() + 1)

const MONTH_NAMES = ['JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE',
                     'JULY','AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER']
const WEEK_LABELS = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun']

function prevMonth() {
  if (viewMonth.value === 1) { viewMonth.value = 12; viewYear.value-- }
  else viewMonth.value--
}
function nextMonth() {
  if (viewMonth.value === 12) { viewMonth.value = 1; viewYear.value++ }
  else viewMonth.value++
}

function localYMD(d: Date) {
  const y = d.getFullYear(); const m = (d.getMonth() + 1).toString().padStart(2, '0')
  const dd = d.getDate().toString().padStart(2, '0')
  return `${y}-${m}-${dd}`
}

const todayYMD = localYMD(now)

interface DayCell {
  date: Date
  ymd: string
  dayNumber: string
  isCurrentMonth: boolean
  isToday: boolean
}

// 6 週 42 格 (起 Monday)
const cells = computed<DayCell[]>(() => {
  const first = new Date(viewYear.value, viewMonth.value - 1, 1)
  const dow = (first.getDay() + 6) % 7
  const gridStart = new Date(first); gridStart.setDate(first.getDate() - dow)
  const out: DayCell[] = []
  for (let i = 0; i < 42; i++) {
    const d = new Date(gridStart); d.setDate(gridStart.getDate() + i)
    out.push({
      date: d,
      ymd: localYMD(d),
      dayNumber: String(d.getDate()).padStart(2, '0'),
      isCurrentMonth: d.getMonth() === viewMonth.value - 1,
      isToday: localYMD(d) === todayYMD,
    })
  }
  return out
})

const bookings = ref<Booking[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchBookings() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const start = `${cells.value[0].ymd}T00:00:00`
  const endNextDay = new Date(cells.value[41].date); endNextDay.setDate(endNextDay.getDate() + 1)
  const end = localYMD(endNextDay) + 'T00:00:00'
  const { data, error: e } = await supabase
    .from('bookings')
    .select(`
      id, start_at, end_at, duration_minutes, status,
      deposit_amount, deposit_status, hold_expires_at, note,
      staff:staff_id ( id, name ),
      service:service_id ( id, name ),
      member:member_id ( id, name, phone )
    `)
    .gte('start_at', start)
    .lt('start_at', end)
    .neq('status', 'cancelled')
    .order('start_at')
  if (e) error.value = e.message
  else bookings.value = (data as any) ?? []
  loading.value = false
}

watch([viewYear, viewMonth, tenant], fetchBookings, { immediate: true })

// 預約 → 依當地日期分組
const bookingsByDay = computed(() => {
  const tz = tenant.value?.timezone ?? 'Asia/Taipei'
  const map = new Map<string, Booking[]>()
  for (const b of bookings.value) {
    const ymd = new Date(b.start_at).toLocaleDateString('sv-SE', { timeZone: tz })
    if (!map.has(ymd)) map.set(ymd, [])
    map.get(ymd)!.push(b)
  }
  return map
})

function fmtTime(iso: string) {
  return new Date(iso).toLocaleTimeString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}

// 取該日「主要事件」用於 cell 上的兩行文字 (title + time);
// 多筆時顯示第一筆 + 「+N」
function dayPrimary(ymd: string) {
  const list = bookingsByDay.value.get(ymd)
  if (!list?.length) return null
  const first = list[0]
  return {
    title: first.service?.name ?? '預約',
    time: fmtTime(first.start_at),
    more: list.length - 1,
    total: list.length,
  }
}

// ---------- 選日展開 ----------
const selectedYMD = ref<string | null>(todayYMD)
const selectedBookings = computed(() => bookingsByDay.value.get(selectedYMD.value ?? '') ?? [])

function statusLabel(s: Booking['status']) {
  return ({ pending: '待確認', confirmed: '已確認', completed: '已完成',
            cancelled: '已取消', no_show: '爽約' } as any)[s]
}
function depositLabel(s: Booking['deposit_status']) {
  return ({ none: '免訂金', pending: '待付', paid: '已付',
            refunded: '已退', forfeited: '沒收' } as any)[s]
}

async function markPaid(b: Booking) {
  const { error: e } = await supabase.from('bookings').update({
    deposit_status: 'paid',
    status: b.status === 'pending' ? 'confirmed' : b.status,
    paid_at: new Date().toISOString(),
    hold_expires_at: null,
  }).eq('id', b.id)
  if (e) error.value = e.message
  await fetchBookings()
}
async function setStatus(b: Booking, status: Booking['status']) {
  const { error: e } = await supabase.from('bookings').update({ status }).eq('id', b.id)
  if (e) error.value = e.message
  await fetchBookings()
}
</script>

<template>
  <div class="page">
    <!-- Top header -->
    <header class="cal-header glass-strong">
      <button class="lg-btn lg-btn-secondary lg-btn-sm nav-btn" @click="prevMonth">‹</button>
      <div class="month-info">
        <span class="lg-title2">{{ MONTH_NAMES[viewMonth - 1] }}</span>
        <span class="lg-subhead lg-muted">{{ viewYear }}</span>
      </div>
      <button class="lg-btn lg-btn-secondary lg-btn-sm nav-btn" @click="nextMonth">›</button>
    </header>

    <!-- Grid -->
    <div class="grid-wrap lg-card">
      <div class="weekdays">
        <div v-for="w in WEEK_LABELS" :key="w" class="weekday">{{ w }}</div>
      </div>

      <div class="grid">
        <button v-for="c in cells" :key="c.ymd"
                class="cell"
                :class="{
                  out: !c.isCurrentMonth,
                  today: c.isToday,
                  has: dayPrimary(c.ymd) && c.isCurrentMonth,
                  selected: selectedYMD === c.ymd,
                }"
                @click="selectedYMD = c.ymd">
          <span class="day-num">{{ c.dayNumber }}</span>
          <template v-if="dayPrimary(c.ymd)">
            <span class="ev-title">{{ dayPrimary(c.ymd)!.title }}</span>
            <span class="ev-time">{{ dayPrimary(c.ymd)!.time }}</span>
            <span v-if="dayPrimary(c.ymd)!.more > 0" class="ev-more">+{{ dayPrimary(c.ymd)!.more }}</span>
          </template>
        </button>
      </div>
    </div>

    <!-- 該日清單 -->
    <section class="day-detail lg-card" v-if="selectedYMD">
      <header class="detail-head">
        <h2 class="lg-title3">{{ selectedYMD }}</h2>
        <span class="lg-pill">{{ selectedBookings.length }} 筆</span>
      </header>
      <p v-if="loading" class="lg-muted">載入中…</p>
      <p v-else-if="!selectedBookings.length" class="lg-muted">當日沒有預約。</p>
      <ul v-else class="booking-list">
        <li v-for="b in selectedBookings" :key="b.id" class="booking-row" :class="['st-' + b.status]">
          <div class="time-col">
            <strong class="lg-headline">{{ fmtTime(b.start_at) }}</strong>
            <span class="lg-caption lg-muted">–{{ fmtTime(b.end_at) }}</span>
          </div>
          <div class="main-col">
            <div class="line1">
              <strong>{{ b.member?.name ?? '—' }}</strong>
              <span class="lg-footnote lg-muted">{{ b.member?.phone }}</span>
            </div>
            <div class="line2">
              <span class="lg-subhead">{{ b.service?.name ?? '—' }}</span>
              <span class="lg-caption lg-muted">· {{ b.duration_minutes }}m · {{ b.staff?.name ?? '—' }}</span>
            </div>
            <div class="line3">
              <span :class="['lg-pill', 'b-' + b.status]">{{ statusLabel(b.status) }}</span>
              <span :class="['lg-pill', 'd-' + b.deposit_status]">{{ depositLabel(b.deposit_status) }}</span>
            </div>
          </div>
          <div class="actions">
            <button v-if="b.deposit_status === 'pending'" class="lg-btn lg-btn-filled lg-btn-sm" @click="markPaid(b)">標訂金已付</button>
            <button v-if="['pending','confirmed'].includes(b.status)" class="lg-btn lg-btn-secondary lg-btn-sm" @click="setStatus(b, 'completed')">完成</button>
            <button v-if="b.status !== 'cancelled'" class="lg-btn lg-btn-danger lg-btn-sm" @click="setStatus(b, 'cancelled')">取消</button>
            <button v-if="['pending','confirmed'].includes(b.status)" class="lg-btn lg-btn-secondary lg-btn-sm" @click="setStatus(b, 'no_show')">爽約</button>
          </div>
        </li>
      </ul>
    </section>

    <p v-if="error" class="lg-pill lg-pill-danger">{{ error }}</p>
  </div>
</template>

<style scoped>
.page {
  display: flex; flex-direction: column; gap: var(--s-3);
}

/* ── Header (sticky pill) ── */
.cal-header {
  display: flex; align-items: center; justify-content: space-between;
  padding: var(--s-2) var(--s-3);
  border-radius: var(--r-pill);
}
.nav-btn {
  width: 36px; height: 36px; padding: 0;
  border-radius: 50%;
  font-size: 22px; font-weight: 600;
  line-height: 1;
}
.month-info { display: flex; align-items: baseline; gap: var(--s-2); }
.month-info .lg-title2 { letter-spacing: -0.02em; }

/* ── Grid card ── */
.grid-wrap {
  display: flex; flex-direction: column; gap: var(--s-2);
  padding: var(--s-3);
}
.weekdays { display: grid; grid-template-columns: repeat(7, 1fr); gap: 6px; }
.weekday {
  text-align: center;
  font-size: var(--t-caption); font-weight: 600;
  letter-spacing: 0.05em;
  color: var(--text-tertiary);
  padding: 6px 0;
  text-transform: uppercase;
}
.grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 6px; }

/* ── Day cell ── */
.cell {
  background: rgba(255, 255, 255, 0.5);
  border: 0.5px solid var(--border-hairline);
  border-radius: var(--r-control);
  padding: 8px 10px;
  cursor: pointer; text-align: left; font: inherit;
  display: flex; flex-direction: column; gap: 2px;
  position: relative;
  aspect-ratio: 1 / 1;
  transition: transform var(--duration-fast) var(--ease-out),
              background var(--duration-fast) var(--ease-out);
  color: var(--text-primary);
}
.cell:hover { background: rgba(255, 255, 255, 0.8); }
.cell:active { transform: scale(0.96); }

.cell.out { opacity: 0.32; }

.cell.today {
  box-shadow: inset 0 0 0 2px var(--accent);
}
.cell.today .day-num { color: var(--accent); font-weight: 700; }

.cell.has {
  background: var(--accent);
  color: white;
  border-color: var(--accent);
}
.cell.has .day-num,
.cell.has .ev-title,
.cell.has .ev-time { color: white; }

.cell.selected {
  box-shadow: inset 0 0 0 2px var(--text-primary);
}
.cell.has.selected {
  box-shadow: inset 0 0 0 2px white;
}

.day-num {
  font-size: var(--t-subhead);
  font-weight: 600;
  letter-spacing: -0.01em;
}
.ev-title {
  font-size: var(--t-caption2); font-weight: 500;
  margin-top: 2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ev-time {
  font-size: var(--t-caption2);
  opacity: 0.8;
}
.ev-more {
  position: absolute; bottom: 6px; right: 8px;
  font-size: 10px; font-weight: 600;
  padding: 1px 6px;
  border-radius: var(--r-pill);
  background: rgba(255, 255, 255, 0.32);
  color: inherit;
}

/* ── Day detail card ── */
.day-detail { display: flex; flex-direction: column; gap: var(--s-3); }
.detail-head { display: flex; align-items: center; gap: var(--s-2); }
.detail-head h2 { margin: 0; }

.booking-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: var(--s-2); }
.booking-row {
  display: grid;
  grid-template-columns: 70px 1fr auto;
  gap: var(--s-3);
  padding: var(--s-3);
  background: rgba(255, 255, 255, 0.5);
  border: 0.5px solid var(--border-hairline);
  border-radius: var(--r-card);
  align-items: center;
}
.time-col { display: flex; flex-direction: column; }
.main-col { display: flex; flex-direction: column; gap: 2px; }
.line1 { display: flex; gap: var(--s-2); align-items: baseline; }
.line2 { display: flex; gap: 4px; align-items: baseline; flex-wrap: wrap; }
.line3 { display: flex; gap: 6px; margin-top: 4px; flex-wrap: wrap; }
.actions { display: flex; flex-wrap: wrap; gap: 4px; justify-content: flex-end; }

.b-pending   { background: var(--warning-fill); color: var(--warning); }
.b-confirmed { background: var(--accent-fill); color: var(--accent); }
.b-completed { background: var(--success-fill); color: var(--success); }
.b-cancelled { background: rgba(120,120,128,0.16); color: var(--text-secondary); }
.b-no_show   { background: var(--danger-fill); color: var(--danger); }
.d-paid    { background: var(--success-fill); color: var(--success); }
.d-pending { background: var(--warning-fill); color: var(--warning); }
.d-none    { background: rgba(120,120,128,0.16); color: var(--text-secondary); }

.booking-row.st-cancelled { opacity: 0.6; }

@media (max-width: 768px) {
  .booking-row { grid-template-columns: 1fr; }
  .actions { justify-content: flex-start; }

  .cell { padding: 4px 6px; border-radius: 8px; }
  .ev-title, .ev-time { display: none; }
  .day-num { font-size: var(--t-caption); }
  .ev-more { bottom: 3px; right: 4px; font-size: 9px; padding: 0 4px; }
  .cell.has::after {
    content: ''; position: absolute; bottom: 4px; left: 4px;
    width: 5px; height: 5px; border-radius: 50%; background: white;
  }
}
</style>
