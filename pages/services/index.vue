<script setup lang="ts">
// 前台 - 服務列表 (公開, SEO)
// 按 service_categories 分組顯示;加購項目 (is_addon) 不出現在這頁,留給主服務牽動
definePageMeta({ layout: 'storefront' })

const supabase = useSupabaseClient()
const tenant = useState<{ id: string; name: string; slug: string } | null>('tenant')
const { publicUrl } = usePortfolio()

useSeoMeta({
  title: () => tenant.value ? `服務項目 · ${tenant.value.name}` : '服務項目',
  description: () => tenant.value
    ? `${tenant.value.name} 提供的服務、價格與時長。點選任一項即可直接預約。`
    : '美業服務列表',
})

interface Service {
  id: string
  name: string
  duration_minutes: number
  price: number
  deposit_amount: number | null
  image_path: string | null
  category_id: string | null
}
interface Category { id: string; name: string; sort_order: number }

const services = ref<Service[]>([])
const categories = ref<Category[]>([])

async function load() {
  if (!tenant.value) return
  const [s, c] = await Promise.all([
    supabase.from('services')
      .select('id, name, duration_minutes, price, deposit_amount, image_path, category_id')
      .eq('tenant_id', tenant.value.id)
      .eq('is_active', true)
      .eq('is_addon', false)
      .order('name'),
    supabase.from('service_categories')
      .select('id, name, sort_order')
      .eq('tenant_id', tenant.value.id)
      .order('sort_order'),
  ])
  services.value = (s.data ?? []) as Service[]
  categories.value = (c.data ?? []) as Category[]
}
await load()

// 分組: 依 category_id; 未分類放最後
const groups = computed(() => {
  const map = new Map<string | null, Service[]>()
  for (const s of services.value) {
    const key = s.category_id ?? null
    if (!map.has(key)) map.set(key, [])
    map.get(key)!.push(s)
  }
  const out: { id: string | null; name: string; items: Service[] }[] = []
  for (const c of categories.value) {
    if (map.has(c.id)) out.push({ id: c.id, name: c.name, items: map.get(c.id)! })
  }
  if (map.has(null)) out.push({ id: null, name: categories.value.length ? '其他' : '所有服務', items: map.get(null)! })
  return out
})
</script>

<template>
  <main class="page">
    <header class="head">
      <h1 class="lg-largetitle">服務項目</h1>
      <p class="lg-callout lg-muted">{{ tenant?.name }}</p>
    </header>

    <p v-if="!services.length" class="lg-muted">尚未公開任何服務。</p>

    <section v-for="g in groups" :key="g.id ?? '__'" class="group">
      <h2 class="group-title">{{ g.name }}</h2>
      <div class="grid">
        <NuxtLink v-for="s in g.items" :key="s.id" :to="`/book?service=${s.id}`" class="card lg-card-tight">
          <img v-if="s.image_path" :src="publicUrl(s.image_path)!" :alt="s.name" class="img" />
          <div v-else class="img placeholder">{{ s.name.charAt(0) }}</div>
          <div class="meta">
            <strong class="lg-headline">{{ s.name }}</strong>
            <span class="lg-footnote lg-muted">{{ s.duration_minutes }} 分 · ${{ s.price }}</span>
            <span v-if="s.deposit_amount" class="lg-pill lg-pill-warning">需訂金 ${{ s.deposit_amount }}</span>
          </div>
        </NuxtLink>
      </div>
    </section>

    <p class="back">
      <NuxtLink to="/" class="lg-btn lg-btn-secondary lg-btn-sm">← 回首頁</NuxtLink>
      <NuxtLink to="/staff" class="lg-btn lg-btn-secondary lg-btn-sm">看設計師</NuxtLink>
      <NuxtLink to="/book" class="lg-btn lg-btn-filled lg-btn-sm">直接預約</NuxtLink>
    </p>
  </main>
</template>

<style scoped>
.page { max-width: 1040px; margin: var(--s-6) auto; padding: 0 var(--s-4); display: flex; flex-direction: column; gap: var(--s-5); }
.head { text-align: center; padding: var(--s-3) 0; }
.head h1 { margin: 0 0 var(--s-1); }

.group { display: flex; flex-direction: column; gap: var(--s-3); }
.group-title {
  font-size: var(--t-title3); font-weight: 600; letter-spacing: -0.015em;
  margin: 0; padding-bottom: var(--s-1);
  border-bottom: 0.5px solid var(--separator);
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: var(--s-3);
}
.card {
  text-decoration: none; color: inherit;
  display: flex; flex-direction: column; gap: var(--s-2);
  padding: 0; overflow: hidden;
  transition: transform var(--duration-fast) var(--ease-out);
}
.card:hover { transform: translateY(-2px); }
.img { width: 100%; aspect-ratio: 16 / 10; object-fit: cover; display: block; background: rgba(120,120,128,0.06); }
.img.placeholder {
  display: flex; align-items: center; justify-content: center;
  font-family: Georgia, serif; font-size: 40px; color: var(--text-tertiary);
  background: var(--accent-fill);
}
.meta { padding: var(--s-3) var(--s-3) var(--s-3); display: flex; flex-direction: column; gap: 4px; align-items: flex-start; }

.back { display: flex; gap: var(--s-2); justify-content: center; flex-wrap: wrap; }
</style>
