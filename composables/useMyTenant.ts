// 取得當前登入老闆所屬的「主店家」。
// MVP 假設一個 user 只屬於一個 tenant; 之後若支援連鎖店,改為列表 + 切換器。
//
// 結果存 useState('my-tenant') 共享, 跨頁面只查一次。
export interface MyTenant {
  id: string
  name: string
  slug: string
  timezone: string
}

export function useMyTenant() {
  const supabase = useSupabaseClient()
  const user = useSupabaseUser()
  const tenant = useState<MyTenant | null>('my-tenant', () => null)
  const loading = useState<boolean>('my-tenant-loading', () => false)
  const error = useState<string | null>('my-tenant-error', () => null)

  async function load(force = false) {
    if (!user.value) { tenant.value = null; return }
    if (tenant.value && !force) return

    loading.value = true
    error.value = null
    try {
      // RLS 已限制只能讀到自己所屬 tenants, 直接取第一筆
      const { data, error: e } = await supabase
        .from('tenants')
        .select('id, name, slug, timezone')
        .limit(1)
        .maybeSingle()
      if (e) throw e
      tenant.value = data
    } catch (e: any) {
      error.value = e?.message ?? 'failed to load tenant'
      tenant.value = null
    } finally {
      loading.value = false
    }
  }

  return { tenant, loading, error, load }
}
