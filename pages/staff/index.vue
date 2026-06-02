<script setup lang="ts">
// 前台 - 設計師列表 (公開頁, 給訪客瀏覽 + SEO)
definePageMeta({ layout: 'storefront' })

const supabase = useSupabaseClient()
const tenant = useState<{ id: string; name: string; slug: string } | null>('tenant')
const { publicUrl } = usePortfolio()

useSeoMeta({
  title: () => tenant.value ? `設計師 · ${tenant.value.name}` : '設計師團隊',
  description: () => tenant.value
    ? `${tenant.value.name} 的設計師團隊與作品集。瀏覽每位設計師的作品後即可預約。`
    : '美業設計師團隊',
})

interface Staff {
  id: string
  name: string
  portfolios: { storage_path: string; caption: string | null }[]
}

const staff = ref<Staff[]>([])
const loading = ref(true)

async function load() {
  if (!tenant.value) return
  // 撈啟用設計師 + 每人前 4 張作品
  const { data: ss } = await supabase
    .from('staff')
    .select('id, name')
    .eq('tenant_id', tenant.value.id)
    .eq('is_active', true)
    .order('created_at')
  const ids = (ss ?? []).map((s: any) => s.id)
  if (ids.length === 0) { staff.value = []; loading.value = false; return }

  const { data: pf } = await supabase
    .from('staff_portfolio')
    .select('staff_id, storage_path, caption, sort_order')
    .in('staff_id', ids)
    .order('sort_order')

  const grouped = new Map<string, { storage_path: string; caption: string | null }[]>()
  for (const row of (pf ?? []) as any[]) {
    const arr = grouped.get(row.staff_id) ?? []
    if (arr.length < 4) arr.push({ storage_path: row.storage_path, caption: row.caption })
    grouped.set(row.staff_id, arr)
  }

  staff.value = (ss ?? []).map((s: any) => ({
    id: s.id, name: s.name,
    portfolios: grouped.get(s.id) ?? [],
  }))
  loading.value = false
}
await load()
</script>

<template>
  <main class="page">
    <header class="head">
      <h1 class="lg-largetitle">設計師團隊</h1>
      <p class="lg-callout lg-muted">{{ tenant?.name }}</p>
    </header>

    <p v-if="loading" class="lg-muted">載入中…</p>
    <p v-else-if="!staff.length" class="lg-muted">尚無設計師資料。</p>

    <section v-else class="grid">
      <NuxtLink v-for="s in staff" :key="s.id" :to="`/staff/${s.id}`" class="card lg-card-tight">
        <div class="thumbs">
          <img v-for="(p, i) in s.portfolios.slice(0, 4)" :key="i"
               :src="publicUrl(p.storage_path)!" :alt="`${s.name} 作品`" />
          <div v-if="!s.portfolios.length" class="no-portfolio">
            <span class="lg-muted">尚無作品</span>
          </div>
        </div>
        <div class="info">
          <strong class="lg-title3">{{ s.name }}</strong>
          <span class="lg-footnote lg-muted">{{ s.portfolios.length }} 件作品</span>
        </div>
      </NuxtLink>
    </section>

    <p class="back">
      <NuxtLink to="/" class="lg-btn lg-btn-secondary lg-btn-sm">← 回首頁</NuxtLink>
      <NuxtLink to="/book" class="lg-btn lg-btn-filled lg-btn-sm">直接預約</NuxtLink>
    </p>
  </main>
</template>

<style scoped>
.page { max-width: 1040px; margin: var(--s-6) auto; padding: 0 var(--s-4); display: flex; flex-direction: column; gap: var(--s-5); }
.head { text-align: center; padding: var(--s-3) 0; }
.head h1 { margin: 0 0 var(--s-1); }

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: var(--s-4);
}
.card {
  text-decoration: none; color: inherit;
  display: flex; flex-direction: column; gap: var(--s-3);
  padding: var(--s-3);
  transition: transform var(--duration-fast) var(--ease-out);
}
.card:hover { transform: translateY(-2px); }
.thumbs {
  display: grid; grid-template-columns: 1fr 1fr; gap: 4px;
  aspect-ratio: 1 / 1; border-radius: var(--r-card); overflow: hidden;
  background: rgba(120,120,128,0.06);
}
.thumbs img { width: 100%; height: 100%; object-fit: cover; }
.no-portfolio {
  grid-column: 1 / -1;
  display: flex; align-items: center; justify-content: center;
  background: rgba(120,120,128,0.08);
}
.info { display: flex; flex-direction: column; gap: 4px; padding: 0 var(--s-2); }
.back { display: flex; gap: var(--s-2); justify-content: center; }
</style>
