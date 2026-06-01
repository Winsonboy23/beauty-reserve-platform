// 取出當前 tenant 的方案狀態 + 用量, 供 UI 顯示 banner / 進度條 / 鎖按鈕
export interface PlanStatus {
  plan: 'free' | 'basic' | 'pro'
  status: 'trialing' | 'active' | 'past_due' | 'paused' | 'canceled'
  trial_ends_at: string | null
  used: {
    bookings_this_month: number
    services: number
    staff: number
    members: number
  }
  limits: {
    bookings_per_month: number   // -1 = 無限
    services: number
    staff: number
    members: number
    can_deposit: boolean
    can_subdomain: boolean
    line_msgs_per_month: number
  }
}

export function usePlanStatus() {
  const supabase = useSupabaseClient()
  const status = useState<PlanStatus | null>('plan-status', () => null)
  const loading = useState<boolean>('plan-status-loading', () => false)

  async function load(tenantId: string, force = false) {
    if (status.value && !force) return
    loading.value = true
    const { data } = await supabase.rpc('plan_status', { p_tenant_id: tenantId })
    status.value = (data as PlanStatus) ?? null
    loading.value = false
  }

  // 用量 / 上限 / 是否已觸頂; -1 表無限
  function usage(kind: 'services' | 'staff' | 'members' | 'bookings_this_month') {
    const s = status.value
    if (!s) return { used: 0, limit: -1, full: false, pct: 0 }
    const used = s.used[kind] as number
    const limitKey: any = kind === 'bookings_this_month' ? 'bookings_per_month' : kind
    const limit = s.limits[limitKey] as number
    if (limit < 0) return { used, limit: -1, full: false, pct: 0 }
    return { used, limit, full: used >= limit, pct: Math.min(100, Math.round((used / limit) * 100)) }
  }

  // 試用剩幾天 (整數,負值代表已過期)
  const trialDaysLeft = computed(() => {
    const s = status.value
    if (!s || s.status !== 'trialing' || !s.trial_ends_at) return null
    const diff = new Date(s.trial_ends_at).getTime() - Date.now()
    return Math.ceil(diff / 86400000)
  })

  return { status, loading, load, usage, trialDaysLeft }
}
