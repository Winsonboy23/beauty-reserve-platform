// 全域 middleware: 從 request host 解析 tenant slug, 載入到 useState('tenant')。
//
// 規則:
//   1. /admin/* 不在這裡解析 (登入後由 useMyTenant 算)
//   2. host 形如 'demo-shop.lvh.me' / 'demo-shop.example.com' → slug = 'demo-shop'
//   3. host 形如 'www.example.com' / 'localhost' / 'example.com' → 沒 slug
//   4. 找不到對應 tenant → 不設 tenant.value, 頁面自己決定如何顯示 (一般是 404)
//
// 本地開發:
//   - localhost:3000 直接打 → 沒 subdomain, 但 fallback env NUXT_PUBLIC_DEFAULT_TENANT_SLUG (相容舊行為)
//   - demo-shop.lvh.me:3000 → 自動解析 'demo-shop' (lvh.me 是公開的 wildcard,*.lvh.me 都解 127.0.0.1)

const RESERVED_SUBDOMAINS = new Set([
  'www', 'app', 'admin', 'api', 'auth', 'static', 'cdn',
  'mail', 'email', 'dashboard', 'docs', 'help', 'support',
  'blog', 'status', 'localhost',
])

// 已知 / 預期的「根網域」結尾 — 用來判斷 host 第一段是不是 subdomain。
// 不在這清單裡的 host 仍可運作 (例: example.com → 視為無 subdomain)。
const KNOWN_ROOT_DOMAINS = ['lvh.me', 'localhost']

function extractSlug(host: string): string | null {
  const hostname = host.split(':')[0].toLowerCase()
  if (!hostname || hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(hostname)) return null

  const parts = hostname.split('.')
  // <slug>.lvh.me → 3 段, slug = parts[0]
  // <slug>.example.com → 3 段
  // example.com → 2 段, 無 subdomain
  if (parts.length < 3) return null

  const candidate = parts[0]
  if (RESERVED_SUBDOMAINS.has(candidate)) return null
  return candidate
}

export default defineNuxtRouteMiddleware(async (to) => {
  if (to.path.startsWith('/admin')) return

  const tenant = useState<{
    id: string; slug: string; name: string; timezone: string
    bank_name?: string | null; bank_account_no?: string | null
    bank_account_holder?: string | null; bank_transfer_note?: string | null
  } | null>('tenant', () => null)
  if (tenant.value) return

  // 取 host (server-side 用 request header, client-side 用 location)
  let host = ''
  if (process.server) {
    host = useRequestHeaders(['host']).host ?? ''
  } else if (process.client) {
    host = location.host
  }

  let slug = extractSlug(host)

  // Fallback: env 預設 slug (本地 localhost 直接 dev 用)
  if (!slug) {
    const config = useRuntimeConfig()
    slug = config.public.defaultTenantSlug || null
  }
  if (!slug) return

  const supabase = useSupabaseClient()
  // 只查 core 欄位; bank_* 等選用欄位由 /book、/manage 自己 lazy load,
  // 避免 0004 / 0008 等 migration 還沒跑時整個 middleware 失效。
  const { data } = await supabase
    .from('tenants')
    .select('id, slug, name, timezone')
    .eq('slug', slug)
    .maybeSingle()

  if (data) tenant.value = data
})
