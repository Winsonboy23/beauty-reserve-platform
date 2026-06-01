<script setup lang="ts">
// 後台 - 月視圖日曆
// 視覺風格參考使用者提供的米黃 + 圓角方塊。
// 點某天 → 下方展開該日預約清單 + 動作。
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

// 顯示的月份 (1-12) 與年份
const now = new Date()
const viewYear = ref(now.getFullYear())
const viewMonth = ref(now.getMonth() + 1) // 1-12

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

// ---------- 構建 6 週 42 格 (起 Monday) ----------
interface DayCell {
  date: Date
  ymd: string      // YYYY-MM-DD (店家當地)
  day: number
  isCurrentMonth: boolean
  isToday: boolean
}

function localYMD(d: Date) {
  const y = d.getFullYear(); const m = (d.getMonth() + 1).toString().padStart(2, '0')
  const dd = d.getDate().toString().padStart(2, '0')
  return `${y}-${m}-${dd}`
}

const todayYMD = localYMD(now)

const cells = computed<DayCell[]>(() => {
  const first = new Date(viewYear.value, viewMonth.value - 1, 1)
  // 把週日 (0) 轉成 6 -> Mon=0
  const dow = (first.getDay() + 6) % 7
  const gridStart = new Date(first); gridStart.setDate(first.getDate() - dow)
  const list: DayCell[] = []
  for (let i = 0; i < 42; i++) {
    const d = new Date(gridStart); d.setDate(gridStart.getDate() + i)
    list.push({
      date: d,
      ymd: localYMD(d),
      day: d.getDate(),
      isCurrentMonth: d.getMonth() === viewMonth.value - 1,
      isToday: localYMD(d) === todayYMD,
    })
  }
  return list
})

// 顯示範圍 (用於 DB query)
const gridStartYMD = computed(() => cells.value[0].ymd)
const gridEndYMD = computed(() => cells.value[41].ymd)

// ---------- 拉預約 ----------
const bookings = ref<Booking[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchBookings() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const start = `${gridStartYMD.value}T00:00:00`
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
    // 利用 sv-SE locale 取 YYYY-MM-DD 格式
    const ymd = new Date(b.start_at).toLocaleDateString('sv-SE', { timeZone: tz })
    if (!map.has(ymd)) map.set(ymd, [])
    map.get(ymd)!.push(b)
  }
  return map
})

// ---------- 選日 ----------
const selectedYMD = ref<string | null>(todayYMD)
function selectDay(c: DayCell) {
  selectedYMD.value = c.ymd
}
const selectedBookings = computed(() => bookingsByDay.value.get(selectedYMD.value ?? '') ?? [])

function fmtTime(iso: string) {
  return new Date(iso).toLocaleTimeString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
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
    <!-- 月份切換 -->
    <div class="cal-frame">
      <button class="nav prev" @click="prevMonth" aria-label="上個月">‹</button>

      <div class="cal-content">
        <div class="month-label">{{ MONTH_NAMES[viewMonth - 1] }} {{ viewYear }}</div>

        <div class="grid">
          <div v-for="w in WEEK_LABELS" :key="w" class="weekday">{{ w }}</div>

          <button v-for="c in cells" :key="c.ymd"
                  class="cell"
                  :class="{
                    out: !c.isCurrentMonth,
                    today: c.isToday,
                    has: bookingsByDay.get(c.ymd)?.length,
                    selected: selectedYMD === c.ymd,
                  }"
                  @click="selectDay(c)">
            <span class="day-num">{{ String(c.day).padStart(2, '0') }}</span>
            <span v-if="bookingsByDay.get(c.ymd)?.length" class="count">
              {{ bookingsByDay.get(c.ymd)!.length }} 筆
            </span>
            <span v-if="bookingsByDay.get(c.ymd)?.[0]" class="first-time">
              {{ fmtTime(bookingsByDay.get(c.ymd)![0].start_at) }}
            </span>
          </button>
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
.page { background: #fbf6e8; padding: 2rem 1rem; margin: -1.5rem; min-height: calc(100vh - 60px); }
.cal-frame {
  display: flex; align-items: stretch; gap: 1rem; max-width: 1100px; margin: 0 auto;
}
.nav {
  background: transparent; border: 0; cursor: pointer; font-size: 2.5rem;
  color: #444; padding: 0 0.5rem; align-self: center;
}
.nav:hover { color: #000; }
.cal-content { flex: 1; display: grid; grid-template-columns: auto 1fr; gap: 1.5rem; align-items: stretch; }
.month-label {
  writing-mode: vertical-rl; transform: rotate(180deg);
  font-size: 2rem; letter-spacing: 0.15em; color: #444;
  font-weight: 300; align-self: stretch; padding: 1rem 0;
}
.grid {
  display: grid; grid-template-columns: repeat(7, 1fr); gap: 0.5rem;
  grid-auto-rows: minmax(78px, 1fr);
}
.weekday {
  text-align: center; font-size: 0.85rem; color: #888; padding-bottom: 0.4rem;
  letter-spacing: 0.05em;
}
.cell {
  background: #fffbef; border: 1.5px solid #2b2b2b; border-radius: 18px;
  padding: 0.55rem 0.6rem; cursor: pointer; text-align: left;
  display: flex; flex-direction: column; gap: 0.15rem;
  font: inherit; transition: transform 0.05s;
}
.cell:hover { transform: translateY(-1px); }
.cell.out { opacity: 0.3; }
.cell.today { box-shadow: 0 0 0 2px #444 inset; }
.cell.has { background: #f5b945; border-color: #2b2b2b; }
.cell.selected { box-shadow: 0 0 0 3px #000 inset; }
.day-num { font-size: 0.95rem; color: #1a1a1a; font-weight: 500; }
.count { font-size: 0.75rem; color: #1a1a1a; opacity: 0.85; }
.first-time { font-size: 0.7rem; color: #1a1a1a; opacity: 0.7; }

.day-detail {
  max-width: 1100px; margin: 2rem auto 0; background: #fff;
  padding: 1.25rem 1.5rem; border-radius: 8px; border: 1px solid #eee;
}
.day-detail h2 { margin: 0 0 0.75rem; font-size: 1.1rem; }
.muted { color: #888; }
.small { font-size: 0.82rem; }
table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; vertical-align: top; }
th { font-weight: 600; color: #555; font-size: 0.82rem; }
.badge { display: inline-block; font-size: 0.75rem; padding: 0.1rem 0.5rem; border-radius: 4px; background: #eee; }
.b-pending { background: #fff5e6; color: #b35900; }
.b-confirmed { background: #e3f2fd; color: #0d47a1; }
.b-completed { background: #e8f5e9; color: #1b5e20; }
.b-no_show { background: #fce4ec; color: #880e4f; }
.d-paid { background: #e8f5e9; color: #1b5e20; }
.d-pending { background: #fff5e6; color: #b35900; }
.d-none { background: #f5f5f5; color: #777; }
.actions { display: flex; flex-wrap: wrap; gap: 0.3rem; }
button:not(.nav) { padding: 0.35rem 0.65rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.82rem; }
button.ghost { background: #f4f4f4; color: #1a1a1a; }
button.danger { color: #c0392b; }
.err { color: #c0392b; max-width: 1100px; margin: 1rem auto; }
</style>
