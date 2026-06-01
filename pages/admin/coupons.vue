<script setup lang="ts">
// 後台 - 優惠券 / 折扣碼 CRUD
definePageMeta({ middleware: 'auth', layout: 'admin' })

const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
await loadTenant()

interface Coupon {
  id: string
  code: string
  name: string
  discount_type: 'percent' | 'fixed'
  discount_value: number
  min_amount: number | null
  max_uses: number | null
  max_uses_per_member: number | null
  valid_from: string | null
  valid_until: string | null
  is_active: boolean
  created_at: string
  used_count?: number
}

const coupons = ref<Coupon[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

async function fetchAll() {
  if (!tenant.value) return
  loading.value = true
  const { data, error: e } = await supabase
    .from('coupons')
    .select('*')
    .order('created_at', { ascending: false })
  if (e) { error.value = e.message; loading.value = false; return }
  // 同時撈每張券的使用次數
  const ids = (data ?? []).map((c: any) => c.id)
  const uses: Record<string, number> = {}
  if (ids.length) {
    const { data: u } = await supabase
      .from('coupon_uses').select('coupon_id').in('coupon_id', ids)
    for (const r of (u ?? []) as any[]) {
      uses[r.coupon_id] = (uses[r.coupon_id] ?? 0) + 1
    }
  }
  coupons.value = (data ?? []).map((c: any) => ({ ...c, used_count: uses[c.id] ?? 0 }))
  loading.value = false
}
await fetchAll()

// ---------- 新增 ----------
const showForm = ref(false)
const form = reactive({
  code: '',
  name: '',
  discount_type: 'fixed' as 'fixed' | 'percent',
  discount_value: 100,
  min_amount: null as number | null,
  max_uses: null as number | null,
  max_uses_per_member: 1 as number | null,
  valid_until: '',
})
const creating = ref(false)

async function create() {
  if (!tenant.value || !form.code.trim() || !form.name.trim()) return
  creating.value = true
  error.value = null
  const payload: any = {
    tenant_id: tenant.value.id,
    code: form.code.trim().toUpperCase(),
    name: form.name.trim(),
    discount_type: form.discount_type,
    discount_value: form.discount_value,
    min_amount: form.min_amount,
    max_uses: form.max_uses,
    max_uses_per_member: form.max_uses_per_member,
    valid_until: form.valid_until ? new Date(form.valid_until + 'T23:59:59').toISOString() : null,
    is_active: true,
  }
  const { error: e } = await supabase.from('coupons').insert(payload)
  creating.value = false
  if (e) {
    if ((e as any).code === '23505') error.value = '優惠碼已存在,請換一個'
    else error.value = e.message
    return
  }
  // 重置
  form.code = ''; form.name = ''; form.discount_value = 100
  form.min_amount = null; form.max_uses = null; form.max_uses_per_member = 1
  form.valid_until = ''
  showForm.value = false
  await fetchAll()
}

async function toggleActive(c: Coupon) {
  await supabase.from('coupons').update({ is_active: !c.is_active }).eq('id', c.id)
  await fetchAll()
}
async function deleteCoupon(c: Coupon) {
  if (c.used_count && c.used_count > 0) {
    alert('此券已有人使用過,請改用「停用」而非「刪除」。')
    return
  }
  if (!confirm(`刪除優惠券「${c.name}」?`)) return
  await supabase.from('coupons').delete().eq('id', c.id)
  await fetchAll()
}

function fmtDiscount(c: Coupon) {
  return c.discount_type === 'percent' ? `${c.discount_value}%` : `$${c.discount_value}`
}
function fmtDate(iso: string | null) {
  if (!iso) return '永久'
  return new Date(iso).toLocaleDateString('zh-TW')
}
</script>

<template>
  <div>
    <h1>優惠券</h1>

    <section class="card actions-row">
      <button @click="showForm = !showForm">
        {{ showForm ? '收起' : '+ 新增優惠券' }}
      </button>
    </section>

    <section v-if="showForm" class="card">
      <h2>新增優惠券</h2>
      <form class="grid" @submit.prevent="create">
        <label class="field">優惠碼
          <input v-model="form.code" required placeholder="如:WELCOME100 (英數,自動轉大寫)" />
        </label>
        <label class="field">顯示名稱
          <input v-model="form.name" required placeholder="如:新客 100 折抵" />
        </label>

        <label class="field">折扣類型
          <select v-model="form.discount_type">
            <option value="fixed">固定金額 ($)</option>
            <option value="percent">百分比 (%)</option>
          </select>
        </label>
        <label class="field">{{ form.discount_type === 'percent' ? '折扣 %' : '折抵 $' }}
          <input v-model.number="form.discount_value" type="number" min="1"
                 :max="form.discount_type === 'percent' ? 99 : undefined" required />
        </label>

        <label class="field">最低消費 (可空)
          <input v-model.number="form.min_amount" type="number" min="0" placeholder="如:500" />
        </label>
        <label class="field">總用量上限 (可空 = 無限)
          <input v-model.number="form.max_uses" type="number" min="1" placeholder="例:100" />
        </label>
        <label class="field">每人用量上限
          <input v-model.number="form.max_uses_per_member" type="number" min="1" />
        </label>
        <label class="field">截止日 (可空)
          <input v-model="form.valid_until" type="date" />
        </label>

        <button :disabled="creating" type="submit" class="full">{{ creating ? '建立中…' : '建立' }}</button>
      </form>
    </section>

    <section class="card">
      <h2>列表 <span class="muted">({{ coupons.length }})</span></h2>
      <p v-if="loading" class="muted">載入中…</p>
      <p v-else-if="!coupons.length" class="muted">還沒有優惠券。</p>
      <table v-else>
        <thead>
          <tr>
            <th>碼</th><th>名稱</th><th>折扣</th><th>最低消費</th>
            <th>用量</th><th>每人上限</th><th>截止</th><th>狀態</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="c in coupons" :key="c.id" :class="{ inactive: !c.is_active }">
            <td><code>{{ c.code }}</code></td>
            <td>{{ c.name }}</td>
            <td>{{ fmtDiscount(c) }}</td>
            <td>{{ c.min_amount ? `$${c.min_amount}` : '—' }}</td>
            <td>{{ c.used_count }} / {{ c.max_uses ?? '∞' }}</td>
            <td>{{ c.max_uses_per_member ?? '∞' }}</td>
            <td>{{ fmtDate(c.valid_until) }}</td>
            <td>{{ c.is_active ? '啟用' : '已停用' }}</td>
            <td class="actions">
              <button class="ghost" @click="toggleActive(c)">{{ c.is_active ? '停用' : '啟用' }}</button>
              <button class="ghost danger" @click="deleteCoupon(c)">刪除</button>
            </td>
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
.actions-row { padding: 0.75rem 1.25rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 0.7rem; }
.field { display: flex; flex-direction: column; font-size: 0.85rem; gap: 0.25rem; color: #5b5b5b; }
.full { grid-column: 1 / -1; }
table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
th, td { text-align: left; padding: 0.55rem 0.5rem; border-bottom: 1px solid #d9d2bc; }
th { font-weight: 600; color: #7a7570; font-size: 0.82rem; }
code { background: #fff3cd; color: #b35900; padding: 0.1rem 0.5rem; border-radius: 4px; font-weight: 600; }
button { padding: 0.45rem 0.85rem; border: 1px solid #2b2b2b; border-radius: 4px; background: #f5b945; color: #1a1a1a; cursor: pointer; font-size: 0.9rem; }
button.ghost { background: transparent; }
button.ghost:hover { background: #f5b945; }
button.danger { background: transparent; color: #c0392b; border-color: #c0392b; }
button.danger:hover { background: #fde2dd; }
.actions { display: flex; gap: 0.3rem; }
tr.inactive td { opacity: 0.55; }
.err { color: #c0392b; }
</style>
