<script setup lang="ts">
// 後台 - 報表 (營收 / 員工業績 / 服務熱門度 / 新客回訪)
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

const range = ref<number>(30) // 預設過去 30 天
const RANGES = [
  { label: '近 7 天',  value: 7 },
  { label: '近 30 天', value: 30 },
  { label: '近 90 天', value: 90 },
  { label: '近 365 天', value: 365 },
]

interface Report {
  range_days: number
  since: string
  revenue: number
  bookings_total: number
  bookings_by_status: Record<string, number> | null
  staff: { id: string; name: string; completed: number; revenue: number }[]
  services: { id: string; name: string; completed: number; revenue: number }[]
  new_customers: number
  returning_customers: number
}
const report = ref<Report | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

async function load() {
  if (!tenant.value) return
  loading.value = true
  error.value = null
  const { data, error: e } = await supabase.rpc('tenant_report', {
    p_tenant_id: tenant.value.id,
    p_days: range.value,
  })
  if (e) error.value = e.message
  else report.value = data as Report
  loading.value = false
}
watch(range, load, { immediate: false })
watch(tenant, () => { if (tenant.value) load() }, { immediate: true })

const statusLabel = (s: string) => ({
  pending: '待確認', confirmed: '已確認', completed: '已完成',
  cancelled: '已取消', no_show: '爽約',
} as any)[s] ?? s

const totalCustomers = computed(() =>
  (report.value?.new_customers ?? 0) + (report.value?.returning_customers ?? 0),
)
const returningRate = computed(() => {
  if (!report.value || totalCustomers.value === 0) return 0
  return Math.round((report.value.returning_customers / totalCustomers.value) * 100)
})

const maxStaffRevenue = computed(() =>
  report.value?.staff.length ? Math.max(...report.value.staff.map(s => Number(s.revenue))) : 0,
)
const maxServiceRevenue = computed(() =>
  report.value?.services.length ? Math.max(...report.value.services.map(s => Number(s.revenue))) : 0,
)
</script>

<template>
  <div>
    <h1>報表</h1>

    <section class="card filter">
      <span class="muted small">範圍</span>
      <div class="range-tabs">
        <button v-for="r in RANGES" :key="r.value"
                :class="{ active: range === r.value }"
                @click="range = r.value">{{ r.label }}</button>
      </div>
    </section>

    <p v-if="loading" class="muted">計算中…</p>
    <p v-if="error" class="err">{{ error }}</p>

    <template v-if="report && !loading">
      <!-- 4 大指標 -->
      <section class="kpis">
        <div class="kpi card">
          <span class="muted small">營收</span>
          <strong class="lg">${{ Number(report.revenue).toLocaleString() }}</strong>
          <span class="muted small">已完成預約</span>
        </div>
        <div class="kpi card">
          <span class="muted small">預約筆數</span>
          <strong class="lg">{{ report.bookings_total }}</strong>
          <span class="muted small">含取消</span>
        </div>
        <div class="kpi card">
          <span class="muted small">新客 / 回訪</span>
          <strong class="lg">{{ report.new_customers }} / {{ report.returning_customers }}</strong>
          <span class="muted small">回訪率 {{ returningRate }}%</span>
        </div>
        <div class="kpi card">
          <span class="muted small">爽約</span>
          <strong class="lg">{{ report.bookings_by_status?.no_show ?? 0 }}</strong>
          <span class="muted small">no-show 筆數</span>
        </div>
      </section>

      <!-- 預約狀態分佈 -->
      <section class="card">
        <h2>預約狀態</h2>
        <div class="status-row">
          <div v-for="(n, s) in report.bookings_by_status ?? {}" :key="s" class="status-cell">
            <strong>{{ n }}</strong>
            <span class="muted small">{{ statusLabel(s) }}</span>
          </div>
          <div v-if="!report.bookings_by_status" class="muted">無資料</div>
        </div>
      </section>

      <!-- 員工業績 -->
      <section class="card">
        <h2>員工業績</h2>
        <p v-if="!report.staff.length" class="muted">尚無資料。</p>
        <table v-else>
          <thead>
            <tr><th>員工</th><th>完成數</th><th>營收</th><th>占比</th></tr>
          </thead>
          <tbody>
            <tr v-for="s in report.staff" :key="s.id">
              <td>{{ s.name }}</td>
              <td>{{ s.completed }}</td>
              <td>${{ Number(s.revenue).toLocaleString() }}</td>
              <td class="bar-cell">
                <div class="bar">
                  <div class="fill" :style="{
                    width: maxStaffRevenue > 0 ? (Number(s.revenue) / maxStaffRevenue * 100) + '%' : '0%',
                  }"></div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <!-- 服務熱門度 -->
      <section class="card">
        <h2>服務排行</h2>
        <p v-if="!report.services.length" class="muted">尚無資料。</p>
        <table v-else>
          <thead>
            <tr><th>服務</th><th>完成數</th><th>營收</th><th>占比</th></tr>
          </thead>
          <tbody>
            <tr v-for="sv in report.services" :key="sv.id">
              <td>{{ sv.name }}</td>
              <td>{{ sv.completed }}</td>
              <td>${{ Number(sv.revenue).toLocaleString() }}</td>
              <td class="bar-cell">
                <div class="bar">
                  <div class="fill" :style="{
                    width: maxServiceRevenue > 0 ? (Number(sv.revenue) / maxServiceRevenue * 100) + '%' : '0%',
                  }"></div>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <p class="muted small">
        計算範圍從 {{ new Date(report.since).toLocaleDateString('zh-TW') }} 起。
        營收 = 完成預約的實收金額(actual_amount);若未填則以服務牌價 + 加購計算。
      </p>
    </template>
  </div>
</template>

<style scoped>
.card { background: #fdfaf1; padding: 1.25rem 1.5rem; border: 1px solid #2b2b2b; border-radius: 14px; margin-bottom: 1rem; }
.card h2 { font-family: Georgia, serif; font-size: 1.15rem; font-weight: 500; margin: 0 0 0.75rem; }
.muted { color: #7a7570; }
.small { font-size: 0.85rem; }
.err { color: #c0392b; }

.filter { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.range-tabs { display: flex; gap: 0.25rem; }
.range-tabs button {
  padding: 0.35rem 0.85rem;
  background: transparent;
  border: 1px solid #2b2b2b;
  color: #1a1a1a;
  border-radius: 6px;
  font-size: 0.88rem;
  cursor: pointer;
}
.range-tabs button.active { background: #f5b945; font-weight: 600; }

.kpis {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 1rem;
  margin-bottom: 1rem;
}
.kpi {
  display: flex; flex-direction: column; gap: 0.2rem;
  margin-bottom: 0;
}
.kpi strong.lg {
  font-family: Georgia, serif;
  font-size: 2rem; font-weight: 400; color: #1a1a1a;
  margin: 0.1rem 0;
}

.status-row { display: flex; gap: 1.5rem; flex-wrap: wrap; }
.status-cell { display: flex; flex-direction: column; gap: 0.15rem; }
.status-cell strong { font-size: 1.4rem; }

table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #d9d2bc; vertical-align: middle; }
th { font-weight: 600; color: #7a7570; font-size: 0.82rem; }
.bar-cell { width: 35%; }
.bar { height: 10px; background: #f3eedd; border-radius: 5px; overflow: hidden; }
.fill { height: 100%; background: #f5b945; transition: width 0.3s; }
</style>
