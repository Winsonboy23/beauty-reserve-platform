<script setup lang="ts">
// 後台 layout: 需登入 (middleware/auth.ts 守衛 /admin/* 路由)。
// 載入 plan_status,頂部 banner 顯示試用倒數 / 觸頂警告。
const user = useSupabaseUser()
const supabase = useSupabaseClient()
const { tenant, load: loadTenant } = useMyTenant()
const { status, load: loadPlan, trialDaysLeft, usage } = usePlanStatus()

watchEffect(async () => {
  if (user.value) await loadTenant()
  if (tenant.value) await loadPlan(tenant.value.id)
})

const planLabel = computed(() => {
  if (!status.value) return ''
  return ({ free: '免費', basic: '基本', pro: '專業' } as any)[status.value.plan]
})

// 是否有任一項已觸頂
const hitLimit = computed(() => {
  if (!status.value) return false
  return (['services','staff','members','bookings_this_month'] as const).some(k => usage(k).full)
})

async function signOut() {
  await supabase.auth.signOut()
  await navigateTo('/admin/login')
}
</script>

<template>
  <div class="admin">
    <header class="admin-header">
      <strong>後台</strong>
      <nav>
        <NuxtLink to="/admin/calendar">月曆</NuxtLink>
        <NuxtLink to="/admin">清單</NuxtLink>
        <NuxtLink to="/admin/services">服務</NuxtLink>
        <NuxtLink to="/admin/staff">員工</NuxtLink>
        <NuxtLink to="/admin/members">會員</NuxtLink>
        <NuxtLink to="/admin/billing">方案 <span class="chip">{{ planLabel }}</span></NuxtLink>
        <NuxtLink to="/admin/settings">設定</NuxtLink>
        <span v-if="user" class="user">{{ user.email }} <button @click="signOut">登出</button></span>
      </nav>
    </header>

    <!-- 試用倒數 banner -->
    <div v-if="status?.status === 'trialing' && trialDaysLeft !== null && trialDaysLeft <= 3" class="banner warn">
      ⏰ 試用期剩 {{ trialDaysLeft }} 天,到期後自動降級為免費方案。
      <NuxtLink to="/admin/billing">立刻升級 →</NuxtLink>
    </div>

    <!-- 觸頂 banner -->
    <div v-else-if="hitLimit" class="banner danger">
      ⚠️ 你已達到目前方案的上限,部分功能無法新增。
      <NuxtLink to="/admin/billing">升級方案 →</NuxtLink>
    </div>

    <main class="admin-main">
      <slot />
    </main>
  </div>
</template>

<style scoped>
.admin-header {
  display: flex; gap: 1rem; align-items: center;
  padding: 0.75rem 1rem; border-bottom: 1px solid #eee; background: #fff;
}
.admin-header nav { display: flex; gap: 1rem; align-items: center; flex: 1; flex-wrap: wrap; }
.admin-header nav a.router-link-active { font-weight: bold; }
.chip {
  display: inline-block; padding: 0.05rem 0.45rem; border-radius: 8px;
  background: #eef3ff; color: #1a47a8; font-size: 0.7rem; margin-left: 0.2rem; font-weight: 600;
}
.user { margin-left: auto; display: flex; gap: 0.5rem; align-items: center; }
.banner { padding: 0.6rem 1rem; font-size: 0.9rem; }
.banner.warn { background: #fff5e6; color: #b35900; }
.banner.danger { background: #fdecea; color: #b71c1c; }
.banner a { color: inherit; font-weight: 600; margin-left: 0.5rem; }
.admin-main { padding: 1.5rem; }
</style>
