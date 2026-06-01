<script setup lang="ts">
// 後台 layout — 米黃 cream 配色, 對齊月曆視覺
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
    <header class="topbar">
      <div class="brand">後台</div>
      <nav class="links">
        <NuxtLink to="/admin/calendar" class="nav-link">月曆</NuxtLink>
        <NuxtLink to="/admin" class="nav-link">預約</NuxtLink>
        <NuxtLink to="/admin/services" class="nav-link">服務</NuxtLink>
        <NuxtLink to="/admin/staff" class="nav-link">員工</NuxtLink>
        <NuxtLink to="/admin/members" class="nav-link">會員</NuxtLink>
        <NuxtLink to="/admin/reports" class="nav-link">報表</NuxtLink>
        <NuxtLink to="/admin/billing" class="nav-link">
          方案 <span v-if="planLabel" class="chip">{{ planLabel }}</span>
        </NuxtLink>
        <NuxtLink to="/admin/settings" class="nav-link">設定</NuxtLink>
      </nav>
      <div v-if="user" class="user">
        <span class="email">{{ user.email }}</span>
        <button class="ghost" @click="signOut">登出</button>
      </div>
    </header>

    <div v-if="status?.status === 'trialing' && trialDaysLeft !== null && trialDaysLeft <= 3" class="banner warn">
      <span>⏰ 試用期剩 {{ trialDaysLeft }} 天</span>
      <NuxtLink to="/admin/billing">立刻升級 →</NuxtLink>
    </div>
    <div v-else-if="hitLimit" class="banner danger">
      <span>⚠️ 已達方案上限</span>
      <NuxtLink to="/admin/billing">升級方案 →</NuxtLink>
    </div>

    <main class="content">
      <slot />
    </main>
  </div>
</template>

<style scoped>
.admin {
  background: #f3eedd;
  min-height: 100vh;
  padding-bottom: 3rem;
}

/* Top bar */
.topbar {
  display: flex; align-items: center; gap: 1.25rem;
  padding: 0.85rem 1.5rem;
  background: #fdfaf1;
  border-bottom: 1px solid #2b2b2b;
  flex-wrap: wrap;
}
.brand {
  font-family: Georgia, 'Times New Roman', serif;
  font-weight: 400; font-size: 1.15rem; letter-spacing: 0.04em;
  color: #2b2b2b;
}
.links {
  display: flex; gap: 0.15rem; align-items: center; flex: 1; flex-wrap: wrap;
}
.nav-link {
  padding: 0.4rem 0.85rem;
  color: #5b5b5b;
  font-size: 0.92rem;
  text-decoration: none;
  border-radius: 6px;
  transition: color 0.15s, background 0.15s;
  display: inline-flex; align-items: center; gap: 6px;
}
.nav-link:hover { color: #1a1a1a; background: rgba(43, 43, 43, 0.06); }
.nav-link.router-link-exact-active,
.nav-link.router-link-active {
  color: #1a1a1a; font-weight: 600;
  background: #f5b945;
}
.chip {
  display: inline-block;
  padding: 0.05rem 0.45rem;
  border-radius: 8px;
  background: #f5b945;
  color: #1a1a1a;
  font-size: 0.7rem;
  font-weight: 600;
}
.user { display: flex; align-items: center; gap: 0.75rem; margin-left: auto; }
.email { font-size: 0.85rem; color: #7a7570; }
.ghost {
  background: transparent;
  border: 1px solid #2b2b2b;
  color: #1a1a1a;
  padding: 0.35rem 0.85rem;
  border-radius: 6px;
  font-size: 0.85rem;
  cursor: pointer;
}
.ghost:hover { background: #f5b945; }

/* Banner */
.banner {
  display: flex; align-items: center; justify-content: space-between; gap: 1rem;
  padding: 0.7rem 1.5rem;
  border-bottom: 1px solid var(--admin-line-soft, #d9d2bc);
  font-size: 0.9rem;
}
.banner.warn   { background: #fff5e6; color: #b35900; }
.banner.danger { background: #fdecea; color: #b71c1c; }
.banner a { font-weight: 600; }

.content { max-width: 1200px; margin: 0 auto; padding: 1.5rem; }

@media (max-width: 768px) {
  .topbar { padding: 0.75rem 1rem; gap: 0.75rem; }
  .links {
    width: 100%;
    overflow-x: auto;
    flex-wrap: nowrap;
    -webkit-overflow-scrolling: touch;
    scrollbar-width: none;
  }
  .links::-webkit-scrollbar { display: none; }
  .nav-link { white-space: nowrap; flex-shrink: 0; }
  .user { margin-left: auto; }
  .email { display: none; }
  .content { padding: 1rem; }
}
</style>
