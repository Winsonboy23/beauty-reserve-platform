<script setup lang="ts">
// 後台 - 服務管理 (含分類 + 加購)
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
  is_addon: boolean
  category_id: string | null
  image_path: string | null
  created_at: string
}
interface Category { id: string; name: string; sort_order: number }

const services = ref<Service[]>([])
const categories = ref<Category[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchAll() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const [s, c] = await Promise.all([
    supabase.from('services')
      .select('id, name, duration_minutes, price, deposit_amount, is_active, is_addon, category_id, image_path, created_at')
      .order('is_addon').order('created_at', { ascending: false }),
    supabase.from('service_categories')
      .select('id, name, sort_order')
      .order('sort_order'),
  ])
  if (s.error) error.value = s.error.message
  if (c.error) error.value = c.error.message
  services.value = (s.data ?? []) as Service[]
  categories.value = (c.data ?? []) as Category[]
  loading.value = false
}
await fetchAll()

// ---------- 分類 CRUD ----------
const newCatName = ref('')
async function addCategory() {
  if (!tenant.value || !newCatName.value.trim()) return
  const { error: e } = await supabase.from('service_categories').insert({
    tenant_id: tenant.value.id,
    name: newCatName.value.trim(),
    sort_order: categories.value.length,
  })
  if (e) { error.value = e.message; return }
  newCatName.value = ''
  await fetchAll()
}
async function renameCategory(c: Category, name: string) {
  if (!name.trim() || name === c.name) return
  await supabase.from('service_categories').update({ name: name.trim() }).eq('id', c.id)
  await fetchAll()
}
async function deleteCategory(c: Category) {
  if (!confirm(`刪除分類「${c.name}」?屬於此分類的服務不會被刪,但會變成「未分類」。`)) return
  await supabase.from('service_categories').delete().eq('id', c.id)
  await fetchAll()
}

// ---------- 新增服務 ----------
const form = reactive({
  name: '',
  duration_minutes: 60,
  price: 0,
  deposit_amount: null as number | null,
  is_addon: false,
  category_id: null as string | null,
})
const creating = ref(false)

async function create() {
  if (!tenant.value) return
  if (!form.name.trim()) { error.value = '請填服務名稱'; return }
  if (!canAddService.value) { error.value = '已達目前方案的服務上限,請升級方案'; return }
  creating.value = true
  error.value = null
  const { error: e } = await supabase.from('services').insert({
    tenant_id: tenant.value.id,
    name: form.name.trim(),
    duration_minutes: form.duration_minutes,
    price: form.price,
    deposit_amount: form.deposit_amount,
    is_addon: form.is_addon,
    category_id: form.category_id,
    is_active: true,
  })
  creating.value = false
  if (e) { error.value = e.message; return }
  form.name = ''
  form.duration_minutes = 60
  form.price = 0
  form.deposit_amount = null
  form.is_addon = false
  form.category_id = null
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
    is_addon: editForm.is_addon,
    category_id: editForm.category_id,
    is_active: editForm.is_active,
  }
  const { error: e } = await supabase.from('services').update(patch).eq('id', editingId.value)
  if (e) { error.value = e.message; return }
  editingId.value = null
  await fetchAll()
}

async function toggleActive(s: Service) {
  const { error: e } = await supabase.from('services').update({ is_active: !s.is_active }).eq('id', s.id)
  if (e) error.value = e.message
  await fetchAll()
}

// ---------- 上傳代表圖 ----------
async function pickImage(s: Service, ev: Event) {
  const file = (ev.target as HTMLInputElement).files?.[0]
  ;(ev.target as HTMLInputElement).value = ''
  if (!file || !tenant.value) return
  if (file.size > 5 * 1024 * 1024) { error.value = '檔案大於 5MB'; return }

  const ext = buildExt(file)
  const path = `${tenant.value.id}/services/${s.id}/main.${ext}`
  if (s.image_path && s.image_path !== path) await remove(s.image_path)
  const up = await upload(path, file, { upsert: true })
  if (up.error) { error.value = up.error; return }
  const { error: e } = await supabase.from('services').update({ image_path: path }).eq('id', s.id)
  if (e) { error.value = e.message; return }
  await fetchAll()
}

async function deleteImage(s: Service) {
  if (!s.image_path) return
  if (!confirm('刪除這張代表圖?')) return
  await remove(s.image_path)
  const { error: e } = await supabase.from('services').update({ image_path: null }).eq('id', s.id)
  if (e) error.value = e.message
  await fetchAll()
}

function categoryName(id: string | null) {
  if (!id) return '未分類'
  return categories.value.find(c => c.id === id)?.name ?? '未分類'
}
</script>

<template>
  <div>
    <h1>服務管理</h1>
    <p v-if="!tenant" class="muted">尚未綁定店家。</p>

    <!-- ── 分類管理 ── -->
    <section v-if="tenant" class="card">
      <h2>服務分類</h2>
      <p v-if="!categories.length" class="muted small">尚無分類,可選擇先新增 (例如:剪髮、染髮、護髮…)。也可不分類直接建服務。</p>
      <div class="cats">
        <div v-for="c in categories" :key="c.id" class="cat">
          <input :value="c.name" @blur="(ev) => renameCategory(c, (ev.target as HTMLInputElement).value)" />
          <button class="ghost" @click="deleteCategory(c)">×</button>
        </div>
      </div>
      <form class="cat-add" @submit.prevent="addCategory">
        <input v-model="newCatName" placeholder="新分類名稱" />
        <button type="submit">新增分類</button>
      </form>
    </section>

    <!-- ── 新增服務 ── -->
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
        <label>分類
          <select v-model="form.category_id">
            <option :value="null">未分類</option>
            <option v-for="c in categories" :key="c.id" :value="c.id">{{ c.name }}</option>
          </select>
        </label>
        <label>時長(分)<input v-model.number="form.duration_minutes" type="number" min="5" step="5" required /></label>
        <label>價格<input v-model.number="form.price" type="number" min="0" step="50" required /></label>
        <label>訂金<input v-model.number="form.deposit_amount" type="number" min="0" step="50" placeholder="留空 = 不收" /></label>
        <label class="toggle">
          <input v-model="form.is_addon" type="checkbox" />加購項目
        </label>
        <button :disabled="creating || !canAddService" type="submit">{{ creating ? '建立中…' : '新增' }}</button>
      </form>
      <p class="muted small">勾「加購項目」= 不能單獨預約,只能跟主服務搭配選擇(例:護髮、洗髮)。</p>
    </section>

    <!-- ── 服務列表 ── -->
    <section v-if="tenant" class="card">
      <h2>服務列表 <span class="muted">({{ services.length }})</span></h2>
      <p v-if="loading" class="muted">載入中…</p>
      <p v-else-if="!services.length" class="muted">還沒有任何服務。</p>
      <table v-else>
        <thead>
          <tr>
            <th>圖</th><th>名稱</th><th>分類</th><th>時長</th><th>價格</th><th>訂金</th><th>類型</th><th>狀態</th><th></th>
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
              <td>
                <select v-model="editForm.category_id">
                  <option :value="null">未分類</option>
                  <option v-for="c in categories" :key="c.id" :value="c.id">{{ c.name }}</option>
                </select>
              </td>
              <td><input v-model.number="editForm.duration_minutes" type="number" min="5" step="5" /></td>
              <td><input v-model.number="editForm.price" type="number" min="0" step="50" /></td>
              <td><input v-model.number="editForm.deposit_amount" type="number" min="0" step="50" /></td>
              <td>
                <label class="toggle"><input v-model="editForm.is_addon" type="checkbox" /> 加購</label>
              </td>
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
              <td><span class="muted small">{{ categoryName(s.category_id) }}</span></td>
              <td>{{ s.duration_minutes }} 分</td>
              <td>${{ s.price }}</td>
              <td>{{ s.deposit_amount ? `$${s.deposit_amount}` : '—' }}</td>
              <td>
                <span v-if="s.is_addon" class="tag-addon">加購</span>
                <span v-else class="muted small">主服務</span>
              </td>
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
.card { background: #fdfaf1; padding: 1.25rem 1.5rem; border: 1px solid #2b2b2b; border-radius: 14px; margin-bottom: 1rem; }
.card h2 { font-family: Georgia, serif; font-size: 1.15rem; font-weight: 500; margin: 0 0 0.75rem; }
.muted { color: #7a7570; }
.small { font-size: 0.85rem; }
.form-row { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: end; }
.form-row label { display: flex; flex-direction: column; font-size: 0.85rem; gap: 0.25rem; color: #5b5b5b; }
.form-row label.toggle { flex-direction: row; align-items: center; gap: 0.4rem; padding-bottom: 0.55rem; }
.cats { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.6rem; }
.cat { display: inline-flex; gap: 0.25rem; align-items: center; }
.cat input { width: 140px; }
.cat-add { display: flex; gap: 0.5rem; }
.tag-addon { display: inline-block; background: #f5b945; padding: 0.05rem 0.5rem; border-radius: 8px; font-size: 0.75rem; font-weight: 500; }
.warn-text { color: #b35900; font-size: 0.88rem; padding: 0.4rem 0.7rem; background: #fff5e6; border-radius: 4px; margin: 0 0 0.7rem; }
.warn-text a { color: #b35900; font-weight: 600; }
button { padding: 0.45rem 0.85rem; border: 1px solid #2b2b2b; border-radius: 4px; background: #f5b945; color: #1a1a1a; cursor: pointer; font-size: 0.9rem; }
button:disabled { opacity: 0.6; cursor: not-allowed; }
button.ghost { background: transparent; }
button.ghost:hover { background: #f5b945; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #d9d2bc; }
th { font-weight: 600; color: #7a7570; font-size: 0.82rem; }
td input, td select { width: 100%; max-width: 110px; }
.toggle { display: inline-flex; gap: 0.3rem; align-items: center; font-size: 0.85rem; }
tr.inactive td { opacity: 0.55; }
.err { color: #c0392b; font-size: 0.9rem; }

.thumb-cell { position: relative; width: 60px; }
.thumb { width: 50px; height: 50px; border-radius: 6px; overflow: hidden;
  border: 1px dashed #b8a980; cursor: pointer; position: relative;
  display: flex; align-items: center; justify-content: center; background: #fff; }
.thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
.thumb-empty { color: #b8a980; font-size: 1.5rem; }
.thumb input[type="file"] { position: absolute; inset: 0; opacity: 0; cursor: pointer; }
.thumb-x { position: absolute; top: -6px; right: -6px;
  width: 18px; height: 18px; line-height: 14px; padding: 0;
  border-radius: 50%; background: #fde2dd; color: #c0392b; border: 1px solid #c0392b; font-size: 0.8rem; }
</style>
