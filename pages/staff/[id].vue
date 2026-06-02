<script setup lang="ts">
// 前台 - 設計師詳細頁 + 作品集 + 能做服務 + 預約 CTA + JSON-LD
definePageMeta({ layout: 'storefront' })

const route = useRoute()
const supabase = useSupabaseClient()
const tenant = useState<{ id: string; name: string; slug: string } | null>('tenant')
const { publicUrl } = usePortfolio()

const staffId = route.params.id as string

interface Staff { id: string; name: string }
interface Portfolio { id: string; storage_path: string; caption: string | null }
interface Service { id: string; name: string; duration_minutes: number; price: number; category_id: string | null }
interface Category { id: string; name: string }

const staff = ref<Staff | null>(null)
const portfolios = ref<Portfolio[]>([])
const services = ref<Service[]>([])
const categories = ref<Category[]>([])
const loading = ref(true)

async function load() {
  if (!tenant.value) return
  const [s, p, sv, cs] = await Promise.all([
    supabase.from('staff')
      .select('id, name')
      .eq('id', staffId)
      .eq('tenant_id', tenant.value.id)
      .eq('is_active', true)
      .maybeSingle(),
    supabase.from('staff_portfolio')
      .select('id, storage_path, caption, sort_order')
      .eq('staff_id', staffId)
      .order('sort_order'),
    supabase.from('staff_services')
      .select('service:service_id(id, name, duration_minutes, price, is_active, is_addon, category_id)')
      .eq('staff_id', staffId),
    supabase.from('service_categories')
      .select('id, name, sort_order')
      .eq('tenant_id', tenant.value.id)
      .order('sort_order'),
  ])
  staff.value = s.data
  portfolios.value = (p.data ?? []) as Portfolio[]
  services.value = (sv.data ?? [])
    .map((r: any) => r.service)
    .filter((x: any) => x && x.is_active && !x.is_addon) as Service[]
  categories.value = (cs.data ?? []) as Category[]
  loading.value = false
}
await load()

const serviceGroups = computed(() => {
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
  if (map.has(null)) out.push({ id: null, name: categories.value.length ? '其他' : '提供服務', items: map.get(null)! })
  return out
})

// 找不到 → 404
if (!staff.value) {
  throw createError({ statusCode: 404, statusMessage: '找不到此設計師', fatal: true })
}

useSeoMeta({
  title: () => staff.value
    ? `${staff.value.name} · ${tenant.value?.name} 設計師`
    : '設計師',
  description: () => staff.value
    ? `${tenant.value?.name} 的設計師 ${staff.value.name}, 作品集 ${portfolios.value.length} 件。預約查看。`
    : '',
  ogType: 'profile',
})

// JSON-LD (Person + offers)
useHead({
  script: [{
    type: 'application/ld+json',
    children: JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'Person',
      name: staff.value?.name,
      worksFor: { '@type': 'LocalBusiness', name: tenant.value?.name },
      makesOffer: services.value.map(s => ({
        '@type': 'Offer',
        name: s.name,
        price: s.price,
        priceCurrency: 'TWD',
      })),
    }),
  }],
})

const heroImage = computed(() => portfolios.value[0]?.storage_path)
</script>

<template>
  <main class="page">
    <p class="back-link">
      <NuxtLink to="/staff" class="lg-footnote">← 所有設計師</NuxtLink>
    </p>

    <header class="head lg-card-tight">
      <div class="hero">
        <img v-if="heroImage" :src="publicUrl(heroImage)!" :alt="`${staff!.name} 主作品`" />
        <div v-else class="hero-fallback">{{ staff!.name.charAt(0) }}</div>
      </div>
      <div class="info">
        <h1 class="lg-title1">{{ staff!.name }}</h1>
        <p class="lg-callout lg-muted">{{ tenant?.name }} · {{ portfolios.length }} 件作品</p>
        <NuxtLink :to="`/book?staff=${staff!.id}`" class="lg-btn lg-btn-filled book-cta">
          預約 {{ staff!.name }}
        </NuxtLink>
      </div>
    </header>

    <!-- 能做服務 (按分類) -->
    <section v-if="services.length" class="lg-card">
      <h2 class="lg-section-title">提供服務</h2>
      <div v-for="g in serviceGroups" :key="g.id ?? '__'" class="svc-group">
        <h3 v-if="serviceGroups.length > 1" class="svc-group-title">{{ g.name }}</h3>
        <ul class="service-list">
          <li v-for="s in g.items" :key="s.id" class="service-row">
            <NuxtLink :to="`/book?staff=${staff!.id}&service=${s.id}`" class="svc-link">
              <span class="lg-callout">{{ s.name }}</span>
              <span class="lg-footnote lg-muted">{{ s.duration_minutes }} 分 · ${{ s.price }}</span>
            </NuxtLink>
          </li>
        </ul>
      </div>
    </section>

    <!-- 作品集 -->
    <section v-if="portfolios.length" class="lg-card">
      <h2 class="lg-section-title">作品集</h2>
      <div class="portfolio-grid">
        <figure v-for="p in portfolios" :key="p.id" class="portfolio-item">
          <img :src="publicUrl(p.storage_path)!" :alt="p.caption ?? `${staff!.name} 作品`" loading="lazy" />
          <figcaption v-if="p.caption" class="lg-footnote">{{ p.caption }}</figcaption>
        </figure>
      </div>
    </section>

    <section v-else class="lg-card">
      <p class="lg-muted">{{ staff!.name }} 尚未上傳作品。</p>
    </section>
  </main>
</template>

<style scoped>
.page { max-width: 1040px; margin: var(--s-5) auto; padding: 0 var(--s-4); display: flex; flex-direction: column; gap: var(--s-4); }
.back-link { margin: 0; }

.head {
  display: grid; grid-template-columns: 200px 1fr; gap: var(--s-5);
  align-items: center;
  padding: var(--s-5);
}
.hero { aspect-ratio: 1 / 1; border-radius: var(--r-container); overflow: hidden; background: rgba(120,120,128,0.06); }
.hero img { width: 100%; height: 100%; object-fit: cover; }
.hero-fallback {
  width: 100%; height: 100%;
  display: flex; align-items: center; justify-content: center;
  font-family: Georgia, serif; font-size: 72px; color: var(--text-tertiary);
  background: var(--accent-fill);
}
.info { display: flex; flex-direction: column; gap: var(--s-2); }
.info h1 { margin: 0; }
.book-cta { align-self: flex-start; padding: 12px 24px; }

.svc-group { margin-bottom: var(--s-3); }
.svc-group:last-child { margin-bottom: 0; }
.svc-group-title {
  font-size: var(--t-subhead); font-weight: 600;
  color: var(--text-secondary);
  margin: 0 0 var(--s-1); padding-bottom: 4px;
  border-bottom: 0.5px solid var(--separator);
}
.service-list { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 0; }
.service-row { border-bottom: 0.5px solid var(--separator); }
.service-row:last-child { border-bottom: 0; }
.svc-link {
  display: flex; justify-content: space-between; align-items: baseline;
  padding: var(--s-3) 0;
  text-decoration: none; color: inherit;
}
.svc-link:hover { opacity: 0.7; }

.portfolio-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
  gap: var(--s-2);
}
.portfolio-item {
  margin: 0;
  background: rgba(120,120,128,0.06);
  border-radius: var(--r-card);
  overflow: hidden;
}
.portfolio-item img { width: 100%; aspect-ratio: 1 / 1; object-fit: cover; display: block; }
.portfolio-item figcaption {
  padding: var(--s-2) var(--s-3);
  background: rgba(255,255,255,0.6);
}

@media (max-width: 640px) {
  .head { grid-template-columns: 1fr; text-align: center; }
  .hero { max-width: 200px; margin: 0 auto; }
  .info { align-items: center; }
}
</style>
