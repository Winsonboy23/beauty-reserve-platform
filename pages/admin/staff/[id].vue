<script setup lang="ts">
// 後台 - 員工編輯 + 排班 + 服務指派
// 對應 4 張表:
//   staff                          - 基本資料
//   staff_services                 - 多對多: 員工 ↔ 服務
//   staff_availability_rules       - 週週固定可用時段
//   staff_availability_exceptions  - 例外 (請假 / 加開)
definePageMeta({ middleware: 'auth', layout: 'admin' })

const route = useRoute()
const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
const { publicUrl, upload, remove, buildExt, randomName } = usePortfolio()
await loadTenant()

const staffId = route.params.id as string
const error = ref<string | null>(null)

// ---------- 員工基本資料 ----------
interface Staff { id: string; name: string; is_active: boolean }
const staff = ref<Staff | null>(null)
const editName = ref('')

async function loadStaff() {
  const { data, error: e } = await supabase
    .from('staff').select('id, name, is_active').eq('id', staffId).maybeSingle()
  if (e) { error.value = e.message; return }
  staff.value = data
  editName.value = data?.name ?? ''
}
async function saveStaff() {
  const { error: e } = await supabase
    .from('staff').update({ name: editName.value.trim() }).eq('id', staffId)
  if (e) error.value = e.message
  await loadStaff()
}

// ---------- 服務指派 (staff_services) ----------
interface Service { id: string; name: string; duration_minutes: number; is_active: boolean }
const allServices = ref<Service[]>([])
const linkedServiceIds = ref<Set<string>>(new Set())

async function loadServices() {
  if (!tenant.value) return
  const [{ data: services }, { data: links }] = await Promise.all([
    supabase.from('services')
      .select('id, name, duration_minutes, is_active')
      .order('name'),
    supabase.from('staff_services')
      .select('service_id').eq('staff_id', staffId),
  ])
  allServices.value = (services ?? []) as Service[]
  linkedServiceIds.value = new Set((links ?? []).map((r: any) => r.service_id))
}

async function toggleService(sId: string, checked: boolean) {
  if (!tenant.value) return
  if (checked) {
    const { error: e } = await supabase.from('staff_services').insert({
      tenant_id: tenant.value.id, staff_id: staffId, service_id: sId,
    })
    if (e) { error.value = e.message; return }
    linkedServiceIds.value.add(sId)
  } else {
    const { error: e } = await supabase.from('staff_services')
      .delete().eq('staff_id', staffId).eq('service_id', sId)
    if (e) { error.value = e.message; return }
    linkedServiceIds.value.delete(sId)
  }
  // 觸發 reactivity
  linkedServiceIds.value = new Set(linkedServiceIds.value)
}

// ---------- 週週固定班表 ----------
interface Rule { id: string; weekday: number; start_time: string; end_time: string }
const WEEKDAYS = ['日', '一', '二', '三', '四', '五', '六']
const rules = ref<Rule[]>([])
const newRule = reactive({ weekday: 1, start_time: '10:00', end_time: '19:00' })

async function loadRules() {
  const { data, error: e } = await supabase
    .from('staff_availability_rules')
    .select('id, weekday, start_time, end_time')
    .eq('staff_id', staffId)
    .order('weekday').order('start_time')
  if (e) { error.value = e.message; return }
  rules.value = data as Rule[]
}
async function addRule() {
  if (!tenant.value) return
  if (newRule.end_time <= newRule.start_time) { error.value = '結束時間必須晚於開始'; return }
  const { error: e } = await supabase.from('staff_availability_rules').insert({
    tenant_id: tenant.value.id, staff_id: staffId,
    weekday: newRule.weekday, start_time: newRule.start_time, end_time: newRule.end_time,
  })
  if (e) { error.value = e.message; return }
  await loadRules()
}
async function deleteRule(id: string) {
  const { error: e } = await supabase.from('staff_availability_rules').delete().eq('id', id)
  if (e) error.value = e.message
  await loadRules()
}

// ---------- 例外 (block / extra) ----------
interface Exception {
  id: string; date: string; kind: 'block' | 'extra'
  start_time: string | null; end_time: string | null; reason: string | null
}
const exceptions = ref<Exception[]>([])
const newEx = reactive({
  date: new Date().toISOString().slice(0, 10),
  kind: 'block' as 'block' | 'extra',
  start_time: '' as string,
  end_time: '' as string,
  reason: '',
})

async function loadExceptions() {
  const { data, error: e } = await supabase
    .from('staff_availability_exceptions')
    .select('id, date, kind, start_time, end_time, reason')
    .eq('staff_id', staffId)
    .gte('date', new Date().toISOString().slice(0, 10))   // 只顯示今天起
    .order('date')
  if (e) { error.value = e.message; return }
  exceptions.value = data as Exception[]
}
async function addException() {
  if (!tenant.value) return
  const payload: any = {
    tenant_id: tenant.value.id, staff_id: staffId,
    date: newEx.date, kind: newEx.kind,
    start_time: newEx.start_time || null,
    end_time:   newEx.end_time   || null,
    reason: newEx.reason || null,
  }
  if (payload.start_time && payload.end_time && payload.end_time <= payload.start_time) {
    error.value = '結束時間必須晚於開始'; return
  }
  const { error: e } = await supabase.from('staff_availability_exceptions').insert(payload)
  if (e) { error.value = e.message; return }
  newEx.reason = ''
  newEx.start_time = ''
  newEx.end_time = ''
  await loadExceptions()
}
async function deleteException(id: string) {
  const { error: e } = await supabase.from('staff_availability_exceptions').delete().eq('id', id)
  if (e) error.value = e.message
  await loadExceptions()
}

// ---------- 作品集 ----------
interface PortfolioItem {
  id: string
  storage_path: string
  caption: string | null
  sort_order: number
}
const portfolio = ref<PortfolioItem[]>([])
const uploading = ref(false)

async function loadPortfolio() {
  const { data, error: e } = await supabase
    .from('staff_portfolio')
    .select('id, storage_path, caption, sort_order')
    .eq('staff_id', staffId)
    .order('sort_order')
    .order('created_at', { ascending: false })
  if (e) { error.value = e.message; return }
  portfolio.value = data as PortfolioItem[]
}

async function uploadPortfolio(ev: Event) {
  const input = ev.target as HTMLInputElement
  const files = Array.from(input.files ?? [])
  input.value = ''
  if (!files.length || !tenant.value) return
  uploading.value = true
  error.value = null
  for (const file of files) {
    if (file.size > 5 * 1024 * 1024) { error.value = `${file.name} 超過 5MB,略過`; continue }
    const ext = buildExt(file)
    const path = `${tenant.value.id}/staff/${staffId}/${randomName()}.${ext}`
    const up = await upload(path, file)
    if (up.error) { error.value = up.error; continue }
    await supabase.from('staff_portfolio').insert({
      tenant_id: tenant.value.id, staff_id: staffId, storage_path: path,
      sort_order: portfolio.value.length,
    })
  }
  uploading.value = false
  await loadPortfolio()
}

async function deletePortfolio(item: PortfolioItem) {
  if (!confirm('刪除這張照片?')) return
  await remove(item.storage_path)
  await supabase.from('staff_portfolio').delete().eq('id', item.id)
  await loadPortfolio()
}

async function saveCaption(item: PortfolioItem) {
  await supabase.from('staff_portfolio').update({ caption: item.caption }).eq('id', item.id)
}

// ---------- 初始載入 ----------
await Promise.all([loadStaff(), loadServices(), loadRules(), loadExceptions(), loadPortfolio()])
</script>

<template>
  <div>
    <p><NuxtLink to="/admin/staff">← 回員工列表</NuxtLink></p>

    <h1 v-if="staff">{{ staff.name }} <span class="muted">({{ staff.is_active ? '啟用' : '已停用' }})</span></h1>
    <p v-else class="muted">載入中…</p>

    <!-- 基本資料 -->
    <section class="card">
      <h2>基本資料</h2>
      <div class="form-row">
        <label>姓名<input v-model="editName" /></label>
        <button @click="saveStaff">儲存</button>
      </div>
    </section>

    <!-- 服務指派 -->
    <section class="card">
      <h2>可提供的服務</h2>
      <p v-if="!allServices.length" class="muted">店家還沒有服務,請先到 <NuxtLink to="/admin/services">服務管理</NuxtLink> 建立。</p>
      <div v-else class="services">
        <label v-for="s in allServices" :key="s.id" class="service-chk">
          <input type="checkbox"
                 :checked="linkedServiceIds.has(s.id)"
                 @change="toggleService(s.id, ($event.target as HTMLInputElement).checked)" />
          <span>{{ s.name }} <span class="muted">({{ s.duration_minutes }}分)</span></span>
          <span v-if="!s.is_active" class="tag">已停用</span>
        </label>
      </div>
    </section>

    <!-- 週週固定班表 -->
    <section class="card">
      <h2>週班表 (規則性可用時段)</h2>
      <p class="muted small">同一週幾可以加多段 (如午休拆兩段)。例外日 (請假 / 加開) 在下一區。</p>

      <table v-if="rules.length">
        <thead><tr><th>週幾</th><th>開始</th><th>結束</th><th></th></tr></thead>
        <tbody>
          <tr v-for="r in rules" :key="r.id">
            <td>週{{ WEEKDAYS[r.weekday] }}</td>
            <td>{{ r.start_time?.slice(0, 5) }}</td>
            <td>{{ r.end_time?.slice(0, 5) }}</td>
            <td><button class="ghost" @click="deleteRule(r.id)">刪除</button></td>
          </tr>
        </tbody>
      </table>
      <p v-else class="muted">尚未設定。</p>

      <form class="form-row" @submit.prevent="addRule">
        <label>週幾
          <select v-model.number="newRule.weekday">
            <option v-for="(w, i) in WEEKDAYS" :key="i" :value="i">週{{ w }}</option>
          </select>
        </label>
        <label>開始<input v-model="newRule.start_time" type="time" required /></label>
        <label>結束<input v-model="newRule.end_time" type="time" required /></label>
        <button type="submit">新增時段</button>
      </form>
    </section>

    <!-- 作品集 -->
    <section class="card">
      <h2>作品集 <span class="muted">({{ portfolio.length }} 張)</span></h2>
      <label class="upload-btn">
        {{ uploading ? '上傳中…' : '+ 上傳照片 (可多選, 單檔 5MB 內)' }}
        <input type="file" accept="image/*" multiple :disabled="uploading" @change="uploadPortfolio" />
      </label>
      <div v-if="portfolio.length" class="portfolio-grid">
        <div v-for="p in portfolio" :key="p.id" class="portfolio-item">
          <img :src="publicUrl(p.storage_path)!" :alt="p.caption ?? ''" />
          <button class="del-x" @click="deletePortfolio(p)" title="刪除">×</button>
          <input v-model="p.caption" placeholder="說明 (可空)" class="caption"
                 @blur="saveCaption(p)" @keydown.enter="(($event.target as HTMLInputElement).blur())" />
        </div>
      </div>
      <p v-else class="muted small">還沒有作品。</p>
    </section>

    <!-- 例外日 -->
    <section class="card">
      <h2>例外日 (請假 / 加開)</h2>
      <p class="muted small">block = 該日不可約 (整天則時間留空); extra = 該日加開額外時段。</p>

      <table v-if="exceptions.length">
        <thead><tr><th>日期</th><th>類型</th><th>時段</th><th>備註</th><th></th></tr></thead>
        <tbody>
          <tr v-for="e in exceptions" :key="e.id">
            <td>{{ e.date }}</td>
            <td>{{ e.kind === 'block' ? '請假' : '加開' }}</td>
            <td>
              <template v-if="e.start_time || e.end_time">
                {{ e.start_time?.slice(0, 5) }}–{{ e.end_time?.slice(0, 5) }}
              </template>
              <template v-else>整天</template>
            </td>
            <td>{{ e.reason ?? '—' }}</td>
            <td><button class="ghost" @click="deleteException(e.id)">刪除</button></td>
          </tr>
        </tbody>
      </table>
      <p v-else class="muted">未來沒有設定任何例外。</p>

      <form class="form-row" @submit.prevent="addException">
        <label>日期<input v-model="newEx.date" type="date" required /></label>
        <label>類型
          <select v-model="newEx.kind">
            <option value="block">請假 (不可約)</option>
            <option value="extra">加開</option>
          </select>
        </label>
        <label>開始 (可空=整天)<input v-model="newEx.start_time" type="time" /></label>
        <label>結束<input v-model="newEx.end_time" type="time" /></label>
        <label>備註<input v-model="newEx.reason" placeholder="如:特休" /></label>
        <button type="submit">新增例外</button>
      </form>
    </section>

    <p v-if="error" class="err">{{ error }}</p>
  </div>
</template>

<style scoped>
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h2 { font-size: 1rem; margin: 0 0 0.75rem; }
.muted { color: #888; }
.small { font-size: 0.85rem; }
.form-row { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: end; margin-top: 0.5rem; }
.form-row label { display: flex; flex-direction: column; font-size: 0.85rem; gap: 0.25rem; }
.form-row input, .form-row select { padding: 0.4rem 0.55rem; border: 1px solid #ddd; border-radius: 4px; }
button { padding: 0.45rem 0.85rem; border: 0; border-radius: 4px; background: #1a1a1a; color: #fff; cursor: pointer; font-size: 0.9rem; }
button.ghost { background: #f4f4f4; color: #1a1a1a; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; margin-bottom: 0.5rem; }
th, td { text-align: left; padding: 0.45rem 0.5rem; border-bottom: 1px solid #f1f1f1; }
.services { display: flex; flex-wrap: wrap; gap: 0.75rem; }
.service-chk { display: inline-flex; gap: 0.4rem; align-items: center; padding: 0.4rem 0.7rem; background: #f7f7f7; border-radius: 16px; font-size: 0.9rem; }
.tag { font-size: 0.7rem; background: #eee; color: #888; padding: 0.05rem 0.4rem; border-radius: 8px; margin-left: 0.3rem; }
.err { color: #c0392b; font-size: 0.9rem; }

.upload-btn {
  display: inline-block; padding: 0.55rem 1rem; background: #1a1a1a; color: #fff;
  border-radius: 4px; cursor: pointer; font-size: 0.9rem; margin-bottom: 0.7rem;
}
.upload-btn input { display: none; }
.portfolio-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.7rem;
  margin-top: 0.5rem;
}
.portfolio-item {
  position: relative; background: #fafafa; border-radius: 6px; overflow: hidden;
  display: flex; flex-direction: column;
}
.portfolio-item img { width: 100%; aspect-ratio: 1/1; object-fit: cover; display: block; }
.portfolio-item .del-x {
  position: absolute; top: 6px; right: 6px;
  width: 24px; height: 24px; line-height: 20px; padding: 0;
  border-radius: 50%; background: rgba(0,0,0,0.65); color: #fff; font-size: 1rem;
  border: 0; cursor: pointer;
}
.portfolio-item .caption {
  border: 0; border-top: 1px solid #eee; padding: 0.4rem 0.55rem; font-size: 0.8rem;
  width: 100%; background: #fff;
}
</style>
