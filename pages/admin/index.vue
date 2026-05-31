<script setup lang="ts">
// 後台首頁 — 日曆/預約列表 + 訂金確認
// 第一版用「分日清單」(不是視覺日曆),把核心動作做順,視覺化日曆之後再疊。
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const user = useSupabaseUser()
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

// 預設顯示「未來 14 天」
const rangeStart = ref(new Date().toISOString().slice(0, 10))
const rangeEnd = computed(() => {
  const d = new Date(rangeStart.value)
  d.setDate(d.getDate() + 14)
  return d.toISOString().slice(0, 10)
})

const bookings = ref<Booking[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchBookings() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  // 以店家時區「當地 0:00」到「結束日 24:00」換成 timestamptz 比對
  const tz = tenant.value.timezone
  const startLocal = `${rangeStart.value}T00:00:00`
  const endLocal = `${rangeEnd.value}T00:00:00`
  // 直接以 ISO 字串送進 PostgREST,假定瀏覽器執行 timezone 與店家一致 (台灣 demo OK);
  // 嚴謹做法之後改成在 server 端轉換或用 RPC。
  const { data, error: e } = await supabase
    .from('bookings')
    .select(`
      id, start_at, end_at, duration_minutes, status,
      deposit_amount, deposit_status, hold_expires_at, note,
      staff:staff_id ( id, name ),
      service:service_id ( id, name ),
      member:member_id ( id, name, phone )
    `)
    .gte('start_at', startLocal)
    .lt('start_at', endLocal)
    .neq('status', 'cancelled')
    .order('start_at')
  if (e) { error.value = e.message; loading.value = false; return }
  bookings.value = (data as any) ?? []
  loading.value = false
}
await fetchBookings()

// 依「店家當地日期」分組
const grouped = computed(() => {
  const tz = tenant.value?.timezone ?? 'Asia/Taipei'
  const map = new Map<string, Booking[]>()
  for (const b of bookings.value) {
    const localDate = new Date(b.start_at).toLocaleDateString('zh-TW', {
      timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    }).replace(/\//g, '-')
    if (!map.has(localDate)) map.set(localDate, [])
    map.get(localDate)!.push(b)
  }
  return Array.from(map.entries()).sort(([a], [b]) => a.localeCompare(b))
})

function fmtTime(iso: string) {
  return new Date(iso).toLocaleTimeString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}

// ---------- 動作 ----------
async function markDepositPaid(b: Booking) {
  // 用 mark_deposit_paid 是給 service_role 用的; 後台老闆從前端直接 update。
  // 安全考量: tenant_isolation policy 已限制只能改自己店的; 設 status confirmed + paid_at。
  const { error: e } = await supabase
    .from('bookings')
    .update({
      deposit_status: 'paid',
      status: b.status === 'pending' ? 'confirmed' : b.status,
      paid_at: new Date().toISOString(),
      hold_expires_at: null,
    })
    .eq('id', b.id)
  if (e) { error.value = e.message; return }
  await fetchBookings()
}

async function setStatus(b: Booking, status: Booking['status']) {
  const { error: e } = await supabase
    .from('bookings').update({ status }).eq('id', b.id)
  if (e) error.value = e.message
  await fetchBookings()
}

function statusLabel(s: Booking['status']) {
  return { pending: '待確認', confirmed: '已確認', completed: '已完成', cancelled: '已取消', no_show: '爽約' }[s]
}
function depositLabel(s: Booking['deposit_status']) {
  return { none: '免訂金', pending: '待付款', paid: '已付', refunded: '已退', forfeited: '沒收' }[s]
}
</script>

<template>
  <div>
    <h1>後台日曆</h1>
    <p class="muted small" v-if="user">登入: {{ user.email }} · 店家: {{ tenant?.name ?? '—' }}</p>

    <section class="card filter">
      <label>從<input v-model="rangeStart" type="date" /></label>
      <span class="muted">起算 14 天</span>
      <button @click="fetchBookings">重新整理</button>
    </section>

    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!bookings.length" class="muted">這段期間沒有預約。先到 <NuxtLink to="/book">前台</NuxtLink> 建一筆試試。</p>

    <section v-for="[date, list] in grouped" :key="date" class="card day">
      <h2>{{ date }} <span class="muted">({{ list.length }} 筆)</span></h2>
      <table>
        <thead>
          <tr><th>時間</th><th>客人</th><th>服務</th><th>設計師</th><th>狀態</th><th>訂金</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="b in list" :key="b.id" :class="['st-' + b.status]">
            <td>
              <strong>{{ fmtTime(b.start_at) }}</strong>
              <span class="muted">–{{ fmtTime(b.end_at) }}</span>
            </td>
            <td>
              {{ b.member?.name ?? '—' }}<br>
              <span class="muted small">{{ b.member?.phone }}</span>
            </td>
            <td>{{ b.service?.name ?? '—' }}<span class="muted small"> ({{ b.duration_minutes }}m)</span></td>
            <td>{{ b.staff?.name ?? '—' }}</td>
            <td>
              <span :class="['badge', 'b-' + b.status]">{{ statusLabel(b.status) }}</span>
            </td>
            <td>
              <span :class="['badge', 'd-' + b.deposit_status]">{{ depositLabel(b.deposit_status) }}</span>
              <div v-if="b.deposit_status === 'pending'" class="muted small">${{ b.deposit_amount }}</div>
              <div v-if="b.hold_expires_at" class="muted small">保留至 {{ fmtTime(b.hold_expires_at) }}</div>
            </td>
            <td class="actions">
              <button v-if="b.deposit_status === 'pending'" @click="markDepositPaid(b)">標訂金已付</button>
              <button v-if="b.status === 'pending' || b.status === 'confirmed'" class="ghost" @click="setStatus(b, 'completed')">完成</button>
              <button v-if="b.status !== 'cancelled'" class="ghost danger" @click="setStatus(b, 'cancelled')">取消</button>
              <button v-if="b.status === 'pending' || b.status === 'confirmed'" class="ghost" @click="setStatus(b, 'no_show')">爽約</button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <p v-if="error" class="err">{{ error }}</p>
  </div>
</template>

<style scoped>
.muted { color: #888; }
.small { font-size: 0.82rem; }
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; }
.filter { display: flex; gap: 0.75rem; align-items: center; }
.filter input { padding: 0.4rem 0.55rem; border: 1px solid #ddd; border-radius: 4px; }
table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; vertical-align: top; }
th { font-weight: 600; color: #555; font-size: 0.82rem; }
.badge { display: inline-block; font-size: 0.75rem; padding: 0.1rem 0.5rem; border-radius: 4px; background: #eee; }
.b-pending { background: #fff5e6; color: #b35900; }
.b-confirmed { background: #e3f2fd; color: #0d47a1; }
.b-completed { background: #e8f5e9; color: #1b5e20; }
.b-no_show { background: #fce4ec; color: #880e4f; }
.b-cancelled { background: #f5f5f5; color: #777; }
.d-paid { background: #e8f5e9; color: #1b5e20; }
.d-pending { background: #fff5e6; color: #b35900; }
.d-none { background: #f5f5f5; color: #777; }
.actions { display: flex; flex-wrap: wrap; gap: 0.3rem; }
button { padding: 0.35rem 0.65rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.82rem; }
button.ghost { background: #f4f4f4; color: #1a1a1a; }
button.danger { color: #c0392b; }
.err { color: #c0392b; }
tr.st-cancelled td { opacity: 0.55; }
</style>
