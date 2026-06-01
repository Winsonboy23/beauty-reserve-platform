<script setup lang="ts">
// 後台 - 服務管理 (CRUD)
// 多租戶: 寫入時必須帶 tenant_id, 由 useMyTenant 提供; RLS 會擋掉跨店操作。
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
const { publicUrl, upload, remove, buildExt } = usePortfolio()
const { status: planStatus, load: loadPlan, usage: planUsage } = usePlanStatus()
await loadTenant()
if (tenant.value) await loadPlan(tenant.value.id)

const canAddService = computed(() => !planUsage('services').full)

interface Service {
  id: string
  name: string
  duration_minutes: number
  price: number
  deposit_amount: number | null
  is_active: boolean
  image_path: string | null
  created_at: string
}

const services = ref<Service[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchAll() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const { data, error: e } = await supabase
    .from('services')
    .select('id, name, duration_minutes, price, deposit_amount, is_active, image_path, created_at')
    .order('created_at', { ascending: false })
  if (e) error.value = e.message
  else services.value = data as Service[]
  loading.value = false
}
await fetchAll()

// ---------- 新增 ----------
const form = reactive({
  name: '',
  duration_minutes: 60,
  price: 0,
  deposit_amount: null as number | null,
})
const creating = ref(false)

async function create() {
  if (!tenant.value) return
  if (!form.name.trim()) { error.value = '請填服務名稱'; return }
  if (!canAddService.value) {
    error.value = '已達目前方案的服務上限,請升級方案'
    return
  }
  creating.value = true
  error.value = null
  const { error: e } = await supabase.from('services').insert({
    tenant_id: tenant.value.id,
    name: form.name.trim(),
    duration_minutes: form.duration_minutes,
    price: form.price,
    deposit_amount: form.deposit_amount,
    is_active: true,
  })
  creating.value = false
  if (e) { error.value = e.message; return }
  form.name = ''
  form.duration_minutes = 60
  form.price = 0
  form.deposit_amount = null
  await fetchAll()
}

// ---------- 編輯 (inline) ----------
const editingId = ref<string | null>(null)
const editForm = reactive<Partial<Service>>({})

function startEdit(s: Service) {
  editingId.value = s.id
  Object.assign(editForm, s)
}
function cancelEdit() { editingId.value = null }
async function saveEdit() {
  if (!editingId.value) return
  const patch = {
    name: editForm.name,
    duration_minutes: editForm.duration_minutes,
    price: editForm.price,
    deposit_amount: editForm.deposit_amount ?? null,
    is_active: editForm.is_active,
  }
  const { error: e } = await supabase.from('services').update(patch).eq('id', editingId.value)
  if (e) { error.value = e.message; return }
  editingId.value = null
  await fetchAll()
}

// ---------- 停用 / 啟用 (軟刪除) ----------
// 直接 hard delete 會在已被引用 (staff_services / bookings) 時 FK 擋住, 用 is_active 切換較友善。
async function toggleActive(s: Service) {
  const { error: e } = await supabase
    .from('services')
    .update({ is_active: !s.is_active })
    .eq('id', s.id)
  if (e) { error.value = e.message; return }
  await fetchAll()
}

// ---------- 上傳代表圖 ----------
async function pickImage(s: Service, ev: Event) {
  const file = (ev.target as HTMLInputElement).files?.[0]
  ;(ev.target as HTMLInputElement).value = ''  // 重置讓同檔案可再選
  if (!file || !tenant.value) return
  if (file.size > 5 * 1024 * 1024) { error.value = '檔案大於 5MB'; return }

  const ext = buildExt(file)
  const path = `${tenant.value.id}/services/${s.id}/main.${ext}`

  // 先刪掉舊圖路徑 (副檔名可能不同) 再上傳新圖, 避免殘留
  if (s.image_path && s.image_path !== path) await remove(s.image_path)

  const up = await upload(path, file, { upsert: true })
  if (up.error) { error.value = up.error; return }

  const { error: e } = await supabase.from('services')
    .update({ image_path: path }).eq('id', s.id)
  if (e) { error.value = e.message; return }
  await fetchAll()
}

async function deleteImage(s: Service) {
  if (!s.image_path) return
  if (!confirm('刪除這張代表圖?')) return
  await remove(s.image_path)
  const { error: e } = await supabase.from('services')
    .update({ image_path: null }).eq('id', s.id)
  if (e) error.value = e.message
  await fetchAll()
}
</script>

<template>
  <div>
    <h1>服務管理</h1>
    <p v-if="!tenant" class="muted">尚未綁定店家。</p>

    <section v-if="tenant" class="card">
      <h2>新增服務
        <span v-if="planStatus" class="muted small">
          ({{ planUsage('services').used }} / {{ planUsage('services').limit < 0 ? '無限' : planUsage('services').limit }})
        </span>
      </h2>
      <p v-if="!canAddService" class="warn-text">
        已達目前方案上限 — <NuxtLink to="/admin/billing">升級方案</NuxtLink> 才能再加服務。
      </p>
      <form class="form-row" @submit.prevent="create">
        <label>名稱<input v-model="form.name" required placeholder="如:剪髮" /></label>
        <label>時長(分)<input v-model.number="form.duration_minutes" type="number" min="5" step="5" required /></label>
        <label>價格<input v-model.number="form.price" type="number" min="0" step="50" required /></label>
        <label>訂金(可空)<input v-model.number="form.deposit_amount" type="number" min="0" step="50" placeholder="不收訂金留空" /></label>
        <button :disabled="creating || !canAddService" type="submit">{{ creating ? '建立中…' : '新增' }}</button>
      </form>
    </section>

    <section v-if="tenant" class="card">
      <h2>服務列表 <span class="muted">({{ services.length }})</span></h2>
      <p v-if="loading" class="muted">載入中…</p>
      <p v-else-if="!services.length" class="muted">還沒有任何服務。</p>
      <table v-else>
        <thead>
          <tr>
            <th>圖</th><th>名稱</th><th>時長</th><th>價格</th><th>訂金</th><th>狀態</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="s in services" :key="s.id" :class="{ inactive: !s.is_active }">
            <td class="thumb-cell">
              <label class="thumb">
                <img v-if="s.image_path" :src="publicUrl(s.image_path)!" :alt="s.name" />
                <span v-else class="thumb-empty">+</span>
                <input type="file" accept="image/*" @change="pickImage(s, $event)" />
              </label>
              <button v-if="s.image_path" class="thumb-x" @click="deleteImage(s)" title="刪圖">×</button>
            </td>
            <template v-if="editingId === s.id">
              <td><input v-model="editForm.name" /></td>
              <td><input v-model.number="editForm.duration_minutes" type="number" min="5" step="5" /></td>
              <td><input v-model.number="editForm.price" type="number" min="0" step="50" /></td>
              <td><input v-model.number="editForm.deposit_amount" type="number" min="0" step="50" /></td>
              <td>
                <label class="toggle"><input v-model="editForm.is_active" type="checkbox" /> 啟用</label>
              </td>
              <td class="actions">
                <button @click="saveEdit">儲存</button>
                <button class="ghost" @click="cancelEdit">取消</button>
              </td>
            </template>
            <template v-else>
              <td>{{ s.name }}</td>
              <td>{{ s.duration_minutes }} 分</td>
              <td>${{ s.price }}</td>
              <td>{{ s.deposit_amount ? `$${s.deposit_amount}` : '—' }}</td>
              <td>{{ s.is_active ? '啟用' : '已停用' }}</td>
              <td class="actions">
                <button class="ghost" @click="startEdit(s)">編輯</button>
                <button class="ghost" @click="toggleActive(s)">
                  {{ s.is_active ? '停用' : '啟用' }}
                </button>
              </td>
            </template>
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
.form-row { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: end; }
.form-row label { display: flex; flex-direction: column; font-size: 0.85rem; gap: 0.25rem; }
.form-row input { padding: 0.4rem 0.55rem; border: 1px solid #ddd; border-radius: 4px; min-width: 80px; }
button { padding: 0.45rem 0.85rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.9rem; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
button.ghost { background: #f4f4f4; color: #1a1a1a; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #f1f1f1; }
th { font-weight: 600; color: #555; }
td input { padding: 0.3rem 0.45rem; border: 1px solid #ddd; border-radius: 3px; width: 100px; }
.actions { display: flex; gap: 0.4rem; }
.toggle { display: inline-flex; gap: 0.3rem; align-items: center; font-size: 0.85rem; }
tr.inactive td { color: #aaa; }
.err { color: #c0392b; font-size: 0.9rem; }
.thumb-cell { position: relative; width: 60px; }
.thumb {
  display: block; width: 50px; height: 50px; border-radius: 6px; overflow: hidden;
  border: 1px dashed #ccc; cursor: pointer; position: relative;
  display: flex; align-items: center; justify-content: center;
}
.thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
.thumb-empty { color: #aaa; font-size: 1.5rem; }
.thumb input[type="file"] { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
.thumb-x {
  position: absolute; top: -6px; right: -6px;
  width: 18px; height: 18px; line-height: 14px; padding: 0;
  border-radius: 50%; background: #c0392b; color: #fff; font-size: 0.8rem;
}
.warn-text { color: #b35900; font-size: 0.88rem; padding: 0.4rem 0.7rem; background: #fff5e6; border-radius: 4px; margin: 0 0 0.7rem; }
.warn-text a { color: #b35900; font-weight: 600; }
</style>
