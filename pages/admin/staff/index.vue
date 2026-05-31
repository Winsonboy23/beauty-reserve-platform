<script setup lang="ts">
// 後台 - 員工列表 + 新增。班表 / 服務指派在 /admin/staff/[id]。
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

interface Staff {
  id: string
  name: string
  is_active: boolean
  created_at: string
}

const staffList = ref<Staff[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchAll() {
  if (!tenant.value) return
  loading.value = true
  const { data, error: e } = await supabase
    .from('staff')
    .select('id, name, is_active, created_at')
    .order('created_at', { ascending: false })
  if (e) error.value = e.message
  else staffList.value = data as Staff[]
  loading.value = false
}
await fetchAll()

const newName = ref('')
const creating = ref(false)
async function create() {
  if (!tenant.value || !newName.value.trim()) return
  creating.value = true
  error.value = null
  const { error: e } = await supabase
    .from('staff')
    .insert({ tenant_id: tenant.value.id, name: newName.value.trim(), is_active: true })
  creating.value = false
  if (e) { error.value = e.message; return }
  newName.value = ''
  await fetchAll()
}

async function toggleActive(s: Staff) {
  const { error: e } = await supabase
    .from('staff')
    .update({ is_active: !s.is_active })
    .eq('id', s.id)
  if (e) error.value = e.message
  await fetchAll()
}
</script>

<template>
  <div>
    <h1>員工管理</h1>
    <p v-if="!tenant" class="muted">尚未綁定店家。</p>

    <section v-if="tenant" class="card">
      <h2>新增員工</h2>
      <form class="form-row" @submit.prevent="create">
        <label>姓名<input v-model="newName" required placeholder="如:Amy" /></label>
        <button :disabled="creating" type="submit">{{ creating ? '建立中…' : '新增' }}</button>
      </form>
    </section>

    <section v-if="tenant" class="card">
      <h2>員工列表 <span class="muted">({{ staffList.length }})</span></h2>
      <p v-if="loading" class="muted">載入中…</p>
      <p v-else-if="!staffList.length" class="muted">還沒有任何員工。</p>
      <table v-else>
        <thead><tr><th>姓名</th><th>狀態</th><th></th></tr></thead>
        <tbody>
          <tr v-for="s in staffList" :key="s.id" :class="{ inactive: !s.is_active }">
            <td>
              <NuxtLink :to="`/admin/staff/${s.id}`">{{ s.name }}</NuxtLink>
            </td>
            <td>{{ s.is_active ? '啟用' : '已停用' }}</td>
            <td class="actions">
              <NuxtLink :to="`/admin/staff/${s.id}`" class="btn ghost">編輯 / 排班</NuxtLink>
              <button class="ghost" @click="toggleActive(s)">{{ s.is_active ? '停用' : '啟用' }}</button>
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <p v-if="error" class="err">{{ error }}</p>
  </div>
</template>

<style scoped>
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; }
.muted { color: #888; }
.form-row { display: flex; gap: 0.75rem; align-items: end; }
.form-row label { display: flex; flex-direction: column; font-size: 0.85rem; gap: 0.25rem; }
.form-row input { padding: 0.4rem 0.55rem; border: 1px solid #ddd; border-radius: 4px; }
button, .btn { padding: 0.45rem 0.85rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.9rem; text-decoration: none; display: inline-block; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
button.ghost, .btn.ghost { background: #f4f4f4; color: #1a1a1a; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; }
th { font-weight: 600; color: #555; }
.actions { display: flex; gap: 0.4rem; }
tr.inactive td { color: #aaa; }
tr.inactive a { color: #aaa; }
.err { color: #c0392b; font-size: 0.9rem; }
</style>
