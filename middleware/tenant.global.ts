// 全域 middleware: 解析 tenant (店家)。
// 第一輪只支援單店 demo, 用 NUXT_PUBLIC_DEFAULT_TENANT_SLUG 指定。
// 之後改成從 host 解析子網域: shop.<slug>.yoursaas.tw
export default defineNuxtRouteMiddleware(async (to) => {
  // /admin/* 不需 tenant 解析 (老闆已知道自己屬於哪個 tenant)
  if (to.path.startsWith('/admin')) return

  const tenant = useState<{ id: string; slug: string; name: string; timezone: string } | null>('tenant', () => null)
  if (tenant.value) return

  const supabase = useSupabaseClient()
  const config = useRuntimeConfig()
  const slug = config.public.defaultTenantSlug

  if (!slug) return // demo 階段允許未設定,前台頁自己會提示

  const { data } = await supabase
    .from('tenants')
    .select('id, slug, name, timezone')
    .eq('slug', slug)
    .maybeSingle()

  if (data) tenant.value = data
})
