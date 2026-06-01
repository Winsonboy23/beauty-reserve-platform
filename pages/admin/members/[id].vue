<script setup lang="ts">
// 後台 - 會員詳細頁
// 編輯姓名 / Email / 備註 / 標籤; 看過去 + 未來預約; 簡單統計
// (電話是自然鍵不允許從這裡改, 防止破壞唯一性約束 ↔ 之後若要改另寫一支 RPC)
definePageMeta({ middleware: 'auth', layout: 'admin' })

const route = useRoute()
const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

const memberId = route.params.id as string
const error = ref<string | null>(null)

interface Member {
  id: string; name: string; phone: string; email: string | null
  note: string | null; tags: string[]; is_blacklisted: boolean
  line_user_id: string | null
  created_at: string
}
interface Booking {
  id: string; start_at: string; duration_minutes: number; status: string
  deposit_status: string; note: string | null
  staff: { name: string } | null
  service: { name: string; price: number } | null
}

const member = ref<Member | null>(null)
const form = reactive<Partial<Member>>({ name: '', email: '', note: '', tags: [], line_user_id: '' })
const newTag = ref('')
const saving = ref(false)
const savedOk = ref(false)

const bookings = ref<Booking[]>([])

async function loadMember() {
  const { data, error: e } = await supabase
    .from('members')
    .select('id, name, phone, email, note, tags, is_blacklisted, line_user_id, created_at')
    .eq('id', memberId).maybeSingle()
  if (e) { error.value = e.message; return }
  member.value = data
  if (data) {
    form.name = data.name
    form.email = data.email ?? ''
    form.note = data.note ?? ''
    form.tags = [...(data.tags ?? [])]
    form.line_user_id = data.line_user_id ?? ''
  }
}

async function toggleBlacklist() {
  if (!member.value) return
  const next = !member.value.is_blacklisted
  if (next && !confirm(`確定將 ${member.value.name} 列入黑名單?之後此電話將無法預約。`)) return
  const { error: e } = await supabase
    .from('members').update({ is_blacklisted: next }).eq('id', memberId)
  if (e) { error.value = e.message; return }
  await loadMember()
}

async function loadBookings() {
  const { data, error: e } = await supabase
    .from('bookings')
    .select(`
      id, start_at, duration_minutes, status, deposit_status, note,
      staff:staff_id ( name ),
      service:service_id ( name, price )
    `)
    .eq('member_id', memberId)
    .order('start_at', { ascending: false })
  if (e) { error.value = e.message; return }
  bookings.value = (data as any) ?? []
}

await Promise.all([loadMember(), loadBookings()])

// ---------- 統計 ----------
const stats = computed(() => {
  let total = 0, noShow = 0, completed = 0, lifetimeValue = 0
  for (const b of bookings.value) {
    if (b.status === 'cancelled') continue
    total++
    if (b.status === 'no_show') noShow++
    if (b.status === 'completed') {
      completed++
      lifetimeValue += Number(b.service?.price ?? 0)
    }
  }
  return { total, noShow, completed, lifetimeValue }
})

// 過去 vs 未來分組
const now = new Date()
const pastBookings = computed(() => bookings.value.filter(b => new Date(b.start_at) < now))
const upcomingBookings = computed(() => bookings.value.filter(b => new Date(b.start_at) >= now).reverse())

// ---------- 編輯 ----------
function addTag() {
  const t = newTag.value.trim()
  if (!t || form.tags!.includes(t)) { newTag.value = ''; return }
  form.tags!.push(t)
  newTag.value = ''
}
function removeTag(t: string) {
  form.tags = form.tags!.filter(x => x !== t)
}

async function save() {
  saving.value = true
  error.value = null
  savedOk.value = false
  const { error: e } = await supabase.from('members').update({
    name: form.name!.trim(),
    email: form.email?.trim() || null,
    note: form.note?.trim() || null,
    tags: form.tags ?? [],
    line_user_id: form.line_user_id?.trim() || null,
  }).eq('id', memberId)
  saving.value = false
  if (e) error.value = e.message
  else { savedOk.value = true; await loadMember() }
}

// ---------- 工具 ----------
function fmt(iso: string) {
  return new Date(iso).toLocaleString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  })
}
function statusLabel(s: string) {
  return ({ pending: '待確認', confirmed: '已確認', completed: '已完成',
            cancelled: '已取消', no_show: '爽約' } as any)[s] ?? s
}
</script>

<template>
  <div>
    <p><NuxtLink to="/admin/members">← 回會員列表</NuxtLink></p>

    <h1 v-if="member">
      {{ member.name }}
      <span v-if="member.is_blacklisted" class="badge-bl">黑名單</span>
    </h1>
    <p v-else class="muted">載入中…</p>

    <!-- 統計 -->
    <section v-if="member" class="card stats">
      <div><span class="muted">總預約</span><strong>{{ stats.total }}</strong></div>
      <div><span class="muted">已完成</span><strong>{{ stats.completed }}</strong></div>
      <div>
        <span class="muted">爽約</span>
        <strong :class="{ warn: stats.noShow > 0 }">{{ stats.noShow }}</strong>
        <span v-if="stats.noShow >= 3 && !member.is_blacklisted" class="hint">建議列黑名單</span>
      </div>
      <div><span class="muted">已完成消費</span><strong>${{ stats.lifetimeValue }}</strong></div>
      <div class="bl-action">
        <button
          :class="member.is_blacklisted ? 'ghost' : 'danger'"
          @click="toggleBlacklist"
        >{{ member.is_blacklisted ? '移出黑名單' : '列入黑名單' }}</button>
      </div>
    </section>

    <!-- 編輯 -->
    <section v-if="member" class="card">
      <h2>基本資料</h2>
      <div class="grid">
        <label class="field">姓名<input v-model="form.name" /></label>
        <label class="field">電話 <span class="muted small">(自然鍵不可改)</span>
          <input :value="member.phone" disabled />
        </label>
        <label class="field">Email<input v-model="form.email" /></label>
      </div>

      <label class="field">備註 (膚質 / 過敏 / 偏好 …)
        <textarea v-model="form.note" rows="3" />
      </label>

      <div class="field">
        <label>標籤</label>
        <div class="tags">
          <span v-for="t in form.tags" :key="t" class="tag">
            {{ t }}
            <button type="button" class="tag-x" @click="removeTag(t)">×</button>
          </span>
          <input v-model="newTag" placeholder="加標籤 enter"
                 class="tag-input" @keydown.enter.prevent="addTag" />
        </div>
      </div>

      <label class="field">LINE user ID
        <span class="muted small">從 LINE Official Account Manager → 聊天 → 該客人對話 → 右側資訊 複製 user id</span>
        <input v-model="form.line_user_id" placeholder="如 Uxxxxxx... (沒綁就留空)" />
      </label>

      <div class="actions">
        <button :disabled="saving" @click="save">{{ saving ? '儲存中…' : '儲存' }}</button>
        <span v-if="savedOk" class="ok">已儲存</span>
        <span v-if="error" class="err">{{ error }}</span>
      </div>
    </section>

    <!-- 未來預約 -->
    <section v-if="member && upcomingBookings.length" class="card">
      <h2>未來預約 <span class="muted">({{ upcomingBookings.length }})</span></h2>
      <table>
        <thead><tr><th>時間</th><th>服務</th><th>設計師</th><th>狀態</th><th>訂金</th></tr></thead>
        <tbody>
          <tr v-for="b in upcomingBookings" :key="b.id">
            <td>{{ fmt(b.start_at) }}</td>
            <td>{{ b.service?.name ?? '—' }} <span class="muted small">({{ b.duration_minutes }}m)</span></td>
            <td>{{ b.staff?.name ?? '—' }}</td>
            <td>{{ statusLabel(b.status) }}</td>
            <td>{{ b.deposit_status === 'paid' ? '已付' : b.deposit_status === 'pending' ? '待付' : '免' }}</td>
          </tr>
        </tbody>
      </table>
    </section>

    <!-- 過去歷史 -->
    <section v-if="member" class="card">
      <h2>歷史紀錄 <span class="muted">({{ pastBookings.length }})</span></h2>
      <p v-if="!pastBookings.length" class="muted">尚無歷史。</p>
      <table v-else>
        <thead><tr><th>時間</th><th>服務</th><th>設計師</th><th>狀態</th><th>備註</th></tr></thead>
        <tbody>
          <tr v-for="b in pastBookings" :key="b.id">
            <td>{{ fmt(b.start_at) }}</td>
            <td>{{ b.service?.name ?? '—' }} <span class="muted small">${{ b.service?.price ?? 0 }}</span></td>
            <td>{{ b.staff?.name ?? '—' }}</td>
            <td>{{ statusLabel(b.status) }}</td>
            <td>{{ b.note ?? '—' }}</td>
          </tr>
        </tbody>
      </table>
    </section>
  </div>
</template>

<style scoped>
.muted { color: #888; }
.small { font-size: 0.82rem; }
.warn { color: #c0392b; }
.ok { color: #1a7a3a; font-size: 0.9rem; }
.err { color: #c0392b; font-size: 0.9rem; }
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; }
.stats { display: flex; gap: 2rem; align-items: flex-end; flex-wrap: wrap; }
.stats > div { display: flex; flex-direction: column; gap: 0.2rem; }
.stats strong { font-size: 1.4rem; }
.bl-action { margin-left: auto; }
.hint { font-size: 0.72rem; color: #c0392b; }
.badge-bl { display: inline-block; background: #fde2dd; color: #c0392b; border: 1px solid #c0392b; font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 8px; margin-left: 0.5rem; vertical-align: middle; }
button.danger { background: transparent !important; color: #c0392b !important; border: 1px solid #c0392b !important; }
button.danger:hover { background: #fde2dd !important; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 0.7rem; }
.field { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; margin-top: 0.7rem; }
.field input, .field textarea { padding: 0.45rem 0.6rem; border: 1px solid #ddd; border-radius: 4px; font: inherit; }
.field input:disabled { background: #f4f4f4; color: #888; }
.tags { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; }
.tag { display: inline-flex; align-items: center; background: #eef3ff; color: #1a47a8; padding: 0.15rem 0.55rem; border-radius: 12px; font-size: 0.82rem; gap: 0.2rem; }
.tag-x { background: transparent; border: 0; color: #1a47a8; cursor: pointer; font-size: 1rem; line-height: 1; padding: 0; }
.tag-input { padding: 0.3rem 0.5rem; border: 1px dashed #ccc; border-radius: 12px; font-size: 0.85rem; min-width: 120px; }
.actions { display: flex; gap: 1rem; align-items: center; margin-top: 1rem; }
button { padding: 0.5rem 0.9rem; border: 1px solid #2b2b2b; border-radius: 4px; background: #f5b945; color: #1a1a1a; cursor: pointer; font-size: 0.9rem; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.5rem; border-bottom: 1px solid #f1f1f1; }
th { font-weight: 600; color: #555; font-size: 0.82rem; }
</style>
