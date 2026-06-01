<script setup lang="ts">
// 後台 - 會員列表
// 會員的建立: create_booking RPC 會 upsert (依 tenant_id + phone),
// 所以一般情境下不需要手動建立 - 客人下單就會出現。
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

interface Member {
  id: string
  name: string
  phone: string
  email: string | null
  note: string | null
  tags: string[]
  is_blacklisted: boolean
  created_at: string
}
interface BookingStat {
  member_id: string
  start_at: string
  status: string
}

const members = ref<Member[]>([])
const stats = ref<BookingStat[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const q = ref('')

async function fetchAll() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const [m, b] = await Promise.all([
    supabase.from('members')
      .select('id, name, phone, email, note, tags, is_blacklisted, created_at')
      .order('created_at', { ascending: false }),
    supabase.from('bookings')
      .select('member_id, start_at, status')
      .neq('status', 'cancelled'),
  ])
  if (m.error) error.value = m.error.message
  if (b.error) error.value = b.error.message
  members.value = (m.data ?? []) as Member[]
  stats.value = (b.data ?? []) as BookingStat[]
  loading.value = false
}
await fetchAll()

// 每位會員的預約聚合 (排除取消)
const statByMember = computed(() => {
  const map = new Map<string, { count: number; last: string | null; noShow: number }>()
  for (const b of stats.value) {
    const cur = map.get(b.member_id) ?? { count: 0, last: null, noShow: 0 }
    cur.count++
    if (!cur.last || b.start_at > cur.last) cur.last = b.start_at
    if (b.status === 'no_show') cur.noShow++
    map.set(b.member_id, cur)
  }
  return map
})

const filtered = computed(() => {
  const kw = q.value.trim().toLowerCase()
  if (!kw) return members.value
  return members.value.filter(m =>
    m.name.toLowerCase().includes(kw) ||
    m.phone.includes(kw) ||
    (m.email?.toLowerCase().includes(kw) ?? false),
  )
})

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('zh-TW', {
    timeZone: tenant.value?.timezone ?? 'Asia/Taipei',
    year: 'numeric', month: '2-digit', day: '2-digit',
  })
}
</script>

<template>
  <div>
    <h1>會員管理 <span class="muted">({{ members.length }})</span></h1>

    <section class="card">
      <input v-model="q" type="search" placeholder="搜尋姓名 / 電話 / Email" class="search" />
    </section>

    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!filtered.length && !q" class="muted">尚無會員。客人從 /book 預約後會自動建立。</p>
    <p v-else-if="!filtered.length" class="muted">沒有符合的會員。</p>

    <section v-else class="card">
      <table>
        <thead>
          <tr>
            <th>姓名</th><th>電話</th><th>標籤</th>
            <th>累積預約</th><th>最後造訪</th><th>爽約</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="m in filtered" :key="m.id" :class="{ blacklisted: m.is_blacklisted }">
            <td>
              <NuxtLink :to="`/admin/members/${m.id}`">{{ m.name }}</NuxtLink>
              <span v-if="m.is_blacklisted" class="badge-bl">黑名單</span>
            </td>
            <td>{{ m.phone }}</td>
            <td>
              <span v-for="t in m.tags" :key="t" class="tag">{{ t }}</span>
              <span v-if="!m.tags?.length" class="muted small">—</span>
            </td>
            <td>{{ statByMember.get(m.id)?.count ?? 0 }}</td>
            <td>{{ fmtDate(statByMember.get(m.id)?.last ?? null) }}</td>
            <td>
              <span :class="{ warn: (statByMember.get(m.id)?.noShow ?? 0) > 0 }">
                {{ statByMember.get(m.id)?.noShow ?? 0 }}
              </span>
            </td>
            <td><NuxtLink :to="`/admin/members/${m.id}`" class="btn ghost">查看</NuxtLink></td>
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
.search { width: 100%; max-width: 360px; padding: 0.5rem 0.7rem; border: 1px solid #ddd; border-radius: 4px; font: inherit; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; vertical-align: middle; }
th { font-weight: 600; color: #555; font-size: 0.82rem; }
.tag { display: inline-block; background: #eef3ff; color: #1a47a8; padding: 0.05rem 0.45rem; border-radius: 8px; font-size: 0.75rem; margin-right: 0.25rem; }
.warn { color: #c0392b; font-weight: 600; }
.badge-bl { display: inline-block; background: #c0392b; color: #fff; font-size: 0.7rem; padding: 0.05rem 0.4rem; border-radius: 8px; margin-left: 0.4rem; }
tr.blacklisted { background: #fef5f5; }
.btn { padding: 0.4rem 0.7rem; border-radius: 4px; background: #f4f4f4; color: #1a1a1a; text-decoration: none; font-size: 0.85rem; }
.err { color: #c0392b; }
</style>
