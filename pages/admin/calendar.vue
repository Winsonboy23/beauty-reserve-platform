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
    <div class="cal-frame">
      <button class="nav prev" @click="prevMonth" aria-label="上個月">‹</button>

      <div class="cal-content">
        <div class="month-label">{{ MONTH_NAMES[viewMonth - 1] }}<br><span class="year">{{ viewYear }}</span></div>

        <div class="grid-wrap">
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
      </div>

      <button class="nav next" @click="nextMonth" aria-label="下個月">›</button>
    </div>

    <!-- 該日清單 -->
    <section class="day-detail" v-if="selectedYMD">
      <h2>{{ selectedYMD }} <span class="muted">({{ selectedBookings.length }} 筆)</span></h2>
      <p v-if="loading" class="muted">載入中…</p>
      <p v-else-if="!selectedBookings.length" class="muted">當日沒有預約。</p>
      <table v-else>
        <thead>
          <tr><th>時間</th><th>客人</th><th>服務</th><th>設計師</th><th>狀態</th><th>訂金</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="b in selectedBookings" :key="b.id" :class="['st-' + b.status]">
            <td><strong>{{ fmtTime(b.start_at) }}</strong> <span class="muted small">–{{ fmtTime(b.end_at) }}</span></td>
            <td>{{ b.member?.name ?? '—' }}<br><span class="muted small">{{ b.member?.phone }}</span></td>
            <td>{{ b.service?.name ?? '—' }} <span class="muted small">({{ b.duration_minutes }}m)</span></td>
            <td>{{ b.staff?.name ?? '—' }}</td>
            <td><span :class="['badge','b-' + b.status]">{{ statusLabel(b.status) }}</span></td>
            <td><span :class="['badge','d-' + b.deposit_status]">{{ depositLabel(b.deposit_status) }}</span></td>
            <td class="actions">
              <button v-if="b.deposit_status === 'pending'" @click="markPaid(b)">標訂金已付</button>
              <button v-if="['pending','confirmed'].includes(b.status)" class="ghost" @click="setStatus(b, 'completed')">完成</button>
              <button v-if="b.status !== 'cancelled'" class="ghost danger" @click="setStatus(b, 'cancelled')">取消</button>
              <button v-if="['pending','confirmed'].includes(b.status)" class="ghost" @click="setStatus(b, 'no_show')">爽約</button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <p v-if="error" class="err">{{ error }}</p>
  </div>
</template>

<style scoped>
/* ---------- Page chrome ---------- */
.page {
  background: #f3eedd;            /* 米白 / 奶油 */
  padding: 2rem 1rem;
  margin: -1.5rem;                 /* 拉掉 admin layout 的 padding 讓底色全幅 */
  min-height: calc(100vh - 60px);
}

/* ---------- Calendar frame ---------- */
.cal-frame {
  display: flex; align-items: center; gap: 0.5rem;
  max-width: 1100px; margin: 0 auto;
}
.nav {
  background: transparent; border: 0; cursor: pointer;
  font-size: 3rem; line-height: 1; color: #2b2b2b;
  width: 3rem; padding: 0;
  font-family: Georgia, 'Times New Roman', serif;
}
.nav:hover { color: #000; }

.cal-content {
  flex: 1;
  display: grid;
  grid-template-columns: auto 1fr;
  align-items: center;
  gap: 1rem;
}

/* 月份標籤: 襯線, 垂直 (旋轉 90 度由下往上) */
.month-label {
  font-family: Georgia, 'Cormorant Garamond', 'Times New Roman', serif;
  font-size: 2.5rem;
  letter-spacing: 0.04em;
  color: #2b2b2b;
  writing-mode: vertical-rl;
  transform: rotate(180deg);
  text-align: center;
  font-weight: 300;
  line-height: 1.1;
}
.month-label .year {
  font-size: 1.1rem;
  letter-spacing: 0.1em;
  color: #555;
}

/* ---------- Grid ---------- */
.grid-wrap { display: flex; flex-direction: column; gap: 0.4rem; }
.weekdays {
  display: grid; grid-template-columns: repeat(7, 1fr); gap: 0.5rem;
}
.weekday {
  text-align: center;
  font-size: 0.78rem; color: #5b5b5b;
  letter-spacing: 0.06em;
  padding: 0.3rem 0;
}
.grid {
  display: grid;
  grid-template-columns: repeat(7, 1fr);
  gap: 0.5rem;
}

/* ---------- Day cell ---------- */
.cell {
  background: #fdfaf1;
  border: 1.5px solid #2b2b2b;
  border-radius: 14px;
  padding: 0.55rem 0.7rem;
  cursor: pointer;
  text-align: left;
  font: inherit;
  display: flex; flex-direction: column;
  gap: 0.1rem;
  position: relative;
  aspect-ratio: 1 / 1;       /* 接近正方形 */
  transition: transform 0.06s;
}
.cell:hover { transform: translateY(-1px); }

/* 鄰月: 淡化整張卡 (文字/邊框/事件全部跟著淡) */
.cell.out {
  opacity: 0.35;
  border-color: #6b6b6b;
  background: #f7f2e3;
}

/* 今日: 內部加陰影框 */
.cell.today { box-shadow: inset 0 0 0 2px #444; }

/* 有事件 + 當月: 整張橘黃高亮 */
.cell.has {
  background: #f5b945;
  border-color: #1f1f1f;
}

/* 選中: 黑邊強調 */
.cell.selected { box-shadow: inset 0 0 0 3px #000; }

.day-num {
  font-size: 0.92rem;
  font-weight: 500;
  color: #1a1a1a;
  letter-spacing: 0.02em;
}
.ev-title {
  font-size: 0.78rem;
  color: #1a1a1a;
  margin-top: 0.15rem;
  line-height: 1.15;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ev-time {
  font-size: 0.72rem;
  color: #1a1a1a;
  line-height: 1.1;
}
.ev-more {
  position: absolute; bottom: 0.35rem; right: 0.55rem;
  font-size: 0.66rem; color: #1a1a1a;
  background: rgba(0,0,0,0.08); padding: 0.05rem 0.3rem; border-radius: 8px;
}

/* ---------- Day detail (展開) ---------- */
.day-detail {
  max-width: 1100px; margin: 2rem auto 0;
  background: #fff;
  padding: 1.25rem 1.5rem;
  border-radius: 12px;
  border: 1px solid #e5dfcc;
}
.day-detail h2 { margin: 0 0 0.75rem; font-size: 1.1rem; font-family: Georgia, serif; }
.muted { color: #888; }
.small { font-size: 0.82rem; }

table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; vertical-align: top; }
th { font-weight: 600; color: #555; font-size: 0.82rem; }
.badge { display: inline-block; font-size: 0.75rem; padding: 0.1rem 0.5rem; border-radius: 4px; background: #eee; }
.b-pending   { background: #fff5e6; color: #b35900; }
.b-confirmed { background: #e3f2fd; color: #0d47a1; }
.b-completed { background: #e8f5e9; color: #1b5e20; }
.b-no_show   { background: #fce4ec; color: #880e4f; }
.d-paid    { background: #e8f5e9; color: #1b5e20; }
.d-pending { background: #fff5e6; color: #b35900; }
.d-none    { background: #f5f5f5; color: #777; }
.actions { display: flex; flex-wrap: wrap; gap: 0.3rem; }

/* 注意: 只給 day-detail 區的按鈕,別用 button:not(.nav) 全域覆蓋,
   否則會吃到 .cell 也是 button 的背景 */
.day-detail .actions button {
  padding: 0.35rem 0.65rem; border: 0; border-radius: 4px;
  background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.82rem;
}
.day-detail .actions button.ghost { background: #f4f4f4; color: #1a1a1a; }
.day-detail .actions button.danger { color: #c0392b; }
.err { color: #c0392b; max-width: 1100px; margin: 1rem auto; }
</style>
