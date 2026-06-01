<script setup lang="ts">
// 客人端 dashboard - 自己的預約歷史 + 改期 / 取消
// 未登入 → 導 /login
// 未綁定 member → 輸入電話 claim
// 已綁定 → 看預約清單
definePageMeta({ layout: 'storefront' })

const supabase = useSupabaseClient()
const user = useSupabaseUser()
const tenant = useState<{ id: string; name: string; slug: string; timezone: string } | null>('tenant')

useSeoMeta({ title: '我的預約', description: '查看與管理你的預約' })

// 未登入 → 導 /login
watchEffect(() => {
  if (!user.value) {
    navigateTo({ path: '/login', query: { redirect: '/my' } })
  }
})

// ---------- 載入 / 綁定 member ----------
interface MyMember { id: string; name: string; phone: string; email: string | null; tags: string[] }
const member = ref<MyMember | null>(null)
const memberLoading = ref(false)
const error = ref<string | null>(null)

async function loadMember() {
  if (!user.value || !tenant.value) return
  memberLoading.value = true
  // RLS member_self_read 允許 user 讀自己; 限定當前 tenant
  const { data, error: e } = await supabase
    .from('members')
    .select('id, name, phone, email, tags')
    .eq('tenant_id', tenant.value.id)
    .eq('user_id', user.value.id)
    .maybeSingle()
  memberLoading.value = false
  if (e) { error.value = e.message; return }
  member.value = data
}

// 綁定 (輸入電話) flow
const linkPhone = ref('')
const linking = ref(false)

async function linkMember() {
  if (!tenant.value || !linkPhone.value.trim()) return
  linking.value = true
  error.value = null
  const { error: e } = await supabase.rpc('customer_link_member', {
    p_tenant_id: tenant.value.id,
    p_phone: linkPhone.value.trim(),
  })
  linking.value = false
  if (e) {
    if (e.message.includes('phone_already_claimed')) error.value = '這支電話已被其他帳號綁定,請聯絡店家'
    else if (e.message.includes('invalid_phone')) error.value = '電話格式不正確'
    else error.value = e.message
    return
  }
  await loadMember()
  await loadBookings()
}

// ---------- 載入預約 ----------
interface MyBooking {
  id: string
  start_at: string; end_at: string; duration_minutes: number
  status: 'pending' | 'confirmed' | 'completed' | 'cancelled' | 'no_show'
  deposit_amount: number; deposit_status: string
  note: string | null
  staff: { name: string } | null
  service: { name: string; price: number } | null
}

const bookings = ref<MyBooking[]>([])
const bookingsLoading = ref(false)

async function loadBookings() {
  if (!member.value) return
  bookingsLoading.value = true
  const { data, error: e } = await supabase
    .from('bookings')
    .select(`
      id, start_at, end_at, duration_minutes, status,
      deposit_amount, deposit_status, note,
      staff:staff_id ( name ),
      service:service_id ( name, price )
    `)
    .eq('member_id', member.value.id)
    .order('start_at', { ascending: false })
  bookingsLoading.value = false
  if (e) { error.value = e.message; return }
  bookings.value = (data as any) ?? []
}

await loadMember()
if (member.value) await loadBookings()

watch([user, tenant], async ([u, t]) => {
  if (u && t) { await loadMember(); if (member.value) await loadBookings() }
})

// ---------- 動作 ----------
async function signOut() {
  await supabase.auth.signOut()
  await navigateTo('/login')
}

async function cancelBooking(b: MyBooking) {
  if (!confirm(`確定取消「${b.service?.name}」這筆預約?`)) return
  const { error: e } = await supabase.rpc('customer_cancel', { p_booking_id: b.id })
  if (e) error.value = e.message
  await loadBookings()
}

// 改期需要選新時段 - 先做簡易版: prompt 輸入 ISO 字串。之後可做完整 picker
async function rescheduleBooking(b: MyBooking) {
  const input = prompt(
    `新時段 (ISO 格式, 例: 2026-06-10T14:00:00+08:00)\n目前: ${b.start_at}`,
    b.start_at,
  )
  if (!input) return
  const { error: e } = await supabase.rpc('customer_reschedule', {
    p_booking_id: b.id, p_new_start_at: input,
  })
  if (e) {
    if (e.message.includes('slot_taken')) error.value = '這個時段已被預約,請換一個'
    else if (e.message.includes('slot_unavailable')) error.value = '這個時段不在可預約範圍'
    else if (e.message.includes('booking_not_modifiable')) error.value = '此預約已不可修改'
    else error.value = e.message
    return
  }
  await loadBookings()
}

// ---------- format ----------
const now = new Date()
const upcoming = computed(() => bookings.value.filter(b =>
  new Date(b.start_at) >= now && !['cancelled', 'completed', 'no_show'].includes(b.status)
))
const past = computed(() => bookings.value.filter(b =>
  !upcoming.value.find(u => u.id === b.id)
))

function fmt(iso: string) {
  return new Date(iso).toLocaleString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
const statusLabel = (s: string) => ({
  pending: '待確認', confirmed: '已確認', completed: '已完成',
  cancelled: '已取消', no_show: '爽約',
} as any)[s]
</script>

<template>
  <main class="page">
    <header class="head">
      <div>
        <h1 class="lg-title1">我的預約</h1>
        <p class="lg-subhead lg-muted" v-if="user">{{ user.email }} · {{ tenant?.name }}</p>
      </div>
      <button class="lg-btn lg-btn-secondary lg-btn-sm" @click="signOut">登出</button>
    </header>

    <p v-if="memberLoading" class="lg-muted">載入中…</p>

    <!-- 未綁定 → 輸入電話 -->
    <section v-else-if="!member" class="lg-card">
      <h2 class="lg-section-title">綁定會員</h2>
      <p class="lg-subhead lg-muted">
        在「{{ tenant?.name }}」還沒查到你的會員紀錄。請輸入你過去預約用的電話,
        系統會把它連到此帳號。
      </p>
      <form class="link-form" @submit.prevent="linkMember">
        <label class="lg-field">
          <span class="lg-field-label">電話</span>
          <input v-model="linkPhone" required pattern="[0-9+\-\s]{6,}" class="lg-input" />
        </label>
        <button class="lg-btn lg-btn-filled" :disabled="linking" type="submit">
          {{ linking ? '綁定中…' : '綁定' }}
        </button>
      </form>
      <p class="lg-footnote lg-muted">
        如果之前沒在這家店預約過,可以
        <NuxtLink to="/book">直接預約</NuxtLink>,
        預約成功後再回來這頁綁定。
      </p>
    </section>

    <template v-else>
      <!-- 未來預約 -->
      <section class="lg-card">
        <h2 class="lg-section-title">未來預約 <span class="lg-pill">{{ upcoming.length }}</span></h2>
        <p v-if="bookingsLoading" class="lg-muted">載入中…</p>
        <p v-else-if="!upcoming.length" class="lg-muted">
          目前沒有預約。
          <NuxtLink to="/book">→ 立即預約</NuxtLink>
        </p>
        <ul v-else class="b-list">
          <li v-for="b in upcoming" :key="b.id" class="b-row glass-tinted">
            <div class="b-time">
              <strong class="lg-headline">{{ fmt(b.start_at) }}</strong>
            </div>
            <div class="b-main">
              <span class="lg-callout">{{ b.service?.name }}</span>
              <span class="lg-footnote lg-muted">
                {{ b.duration_minutes }} 分 · {{ b.staff?.name }} · ${{ b.service?.price }}
              </span>
              <div class="b-pills">
                <span :class="['lg-pill', 'b-' + b.status]">{{ statusLabel(b.status) }}</span>
                <span v-if="b.deposit_status === 'pending'" class="lg-pill lg-pill-warning">待付訂金 ${{ b.deposit_amount }}</span>
                <span v-else-if="b.deposit_status === 'paid'" class="lg-pill lg-pill-success">訂金已付</span>
              </div>
            </div>
            <div class="b-actions">
              <button class="lg-btn lg-btn-secondary lg-btn-sm" @click="rescheduleBooking(b)">改期</button>
              <button class="lg-btn lg-btn-danger lg-btn-sm" @click="cancelBooking(b)">取消</button>
            </div>
          </li>
        </ul>
      </section>

      <!-- 歷史 -->
      <section class="lg-card">
        <h2 class="lg-section-title">歷史紀錄 <span class="lg-pill">{{ past.length }}</span></h2>
        <p v-if="!past.length" class="lg-muted">尚無歷史。</p>
        <ul v-else class="b-list">
          <li v-for="b in past" :key="b.id" class="b-row glass-tinted">
            <div class="b-time">
              <span class="lg-subhead">{{ fmt(b.start_at) }}</span>
            </div>
            <div class="b-main">
              <span class="lg-callout">{{ b.service?.name }}</span>
              <span class="lg-footnote lg-muted">
                {{ b.duration_minutes }} 分 · {{ b.staff?.name }}
              </span>
              <span :class="['lg-pill', 'b-' + b.status]">{{ statusLabel(b.status) }}</span>
            </div>
          </li>
        </ul>
      </section>
    </template>

    <p v-if="error" class="lg-pill lg-pill-danger err">{{ error }}</p>
  </main>
</template>

<style scoped>
.page { max-width: 680px; margin: var(--s-6) auto; padding: 0 var(--s-4); display: flex; flex-direction: column; gap: var(--s-4); }
.head { display: flex; align-items: flex-start; justify-content: space-between; gap: var(--s-3); padding: var(--s-3) 0; }
.head h1 { margin: 0 0 var(--s-1); }

.link-form { display: flex; flex-direction: column; gap: var(--s-3); margin: var(--s-3) 0; }

.b-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: var(--s-2); }
.b-row {
  display: grid; grid-template-columns: 1fr auto;
  gap: var(--s-2) var(--s-3);
  padding: var(--s-3) var(--s-4);
  border-radius: var(--r-card);
  align-items: center;
}
.b-time { grid-column: 1 / -1; padding-bottom: 4px; border-bottom: 0.5px dashed var(--border-hairline); margin-bottom: 4px; }
.b-main { display: flex; flex-direction: column; gap: 4px; }
.b-pills { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 4px; }
.b-actions { display: flex; gap: 6px; align-items: center; }

.b-pending   { background: var(--warning-fill); color: var(--warning); }
.b-confirmed { background: var(--accent-fill); color: var(--accent); }
.b-completed { background: var(--success-fill); color: var(--success); }
.b-cancelled { background: rgba(120,120,128,0.16); color: var(--text-secondary); }
.b-no_show   { background: var(--danger-fill); color: var(--danger); }

.err { align-self: flex-start; max-width: 100%; }

@media (max-width: 600px) {
  .b-row { grid-template-columns: 1fr; }
  .b-actions { width: 100%; }
}
</style>
