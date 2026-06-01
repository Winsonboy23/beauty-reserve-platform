<script setup lang="ts">
// 後台 layout - Liquid Glass floating nav bar
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
    <!-- Floating glass nav -->
    <nav class="nav">
      <div class="nav-inner">
        <div class="brand">後台</div>
        <div class="links">
          <NuxtLink to="/admin/calendar">月曆</NuxtLink>
          <NuxtLink to="/admin">清單</NuxtLink>
          <NuxtLink to="/admin/services">服務</NuxtLink>
          <NuxtLink to="/admin/staff">員工</NuxtLink>
          <NuxtLink to="/admin/members">會員</NuxtLink>
          <NuxtLink to="/admin/billing" class="nav-billing">
            方案 <span class="lg-pill lg-pill-accent">{{ planLabel || '—' }}</span>
          </NuxtLink>
          <NuxtLink to="/admin/settings">設定</NuxtLink>
        </div>
        <div v-if="user" class="user">
          <span class="lg-footnote">{{ user.email }}</span>
          <button class="lg-btn lg-btn-secondary lg-btn-sm" @click="signOut">登出</button>
        </div>
      </div>
    </nav>

    <!-- Banners -->
    <div v-if="status?.status === 'trialing' && trialDaysLeft !== null && trialDaysLeft <= 3" class="banner warn">
      <span>⏰ 試用期剩 {{ trialDaysLeft }} 天</span>
      <NuxtLink to="/admin/billing" class="lg-btn lg-btn-filled lg-btn-sm">立刻升級</NuxtLink>
    </div>
    <div v-else-if="hitLimit" class="banner danger">
      <span>⚠️ 已達方案上限,部分功能無法新增</span>
      <NuxtLink to="/admin/billing" class="lg-btn lg-btn-filled lg-btn-sm">升級方案</NuxtLink>
    </div>

    <main class="content">
      <slot />
    </main>
  </div>
</template>

<style scoped>
.admin { min-height: 100vh; padding-bottom: var(--s-7); }

.nav {
  position: sticky; top: var(--s-3); z-index: 50;
  margin: var(--s-3) auto;
  max-width: 1240px;
  padding: 0 var(--s-3);
}
.nav-inner {
  display: flex; align-items: center; gap: var(--s-4);
  padding: var(--s-2) var(--s-3) var(--s-2) var(--s-4);
  background: var(--surface-glass-strong);
  -webkit-backdrop-filter: blur(40px) saturate(200%);
  backdrop-filter: blur(40px) saturate(200%);
  border: 0.5px solid var(--border-hairline);
  border-radius: var(--r-pill);
  box-shadow: var(--shadow-glass);
}
.brand {
  font-weight: 700; letter-spacing: -0.01em; font-size: var(--t-callout);
  padding: 0 var(--s-2);
}
.links {
  display: flex; gap: var(--s-1); align-items: center; flex: 1; flex-wrap: wrap;
}
.links :deep(a) {
  padding: 6px 14px;
  border-radius: var(--r-pill);
  color: var(--text-secondary);
  font-size: var(--t-subhead);
  font-weight: 500;
  transition: background var(--duration-fast), color var(--duration-fast);
  display: inline-flex; align-items: center; gap: 6px;
}
.links :deep(a:hover) {
  background: rgba(120, 120, 128, 0.12);
  color: var(--text-primary);
  opacity: 1;
}
.links :deep(a.router-link-exact-active),
.links :deep(a.router-link-active) {
  background: var(--accent-fill);
  color: var(--accent);
}
.user {
  display: flex; gap: var(--s-2); align-items: center; margin-left: auto;
}

.banner {
  display: flex; align-items: center; justify-content: space-between; gap: var(--s-3);
  max-width: 1240px; margin: 0 auto var(--s-3);
  padding: var(--s-3) var(--s-4);
  border-radius: var(--r-card);
  font-size: var(--t-subhead);
  font-weight: 500;
}
.banner.warn   { background: var(--warning-fill); color: var(--warning); }
.banner.danger { background: var(--danger-fill);  color: var(--danger); }

.content {
  max-width: 1240px; margin: 0 auto;
  padding: 0 var(--s-4) var(--s-6);
}

@media (max-width: 768px) {
  .nav { margin-top: var(--s-2); }
  .nav-inner {
    flex-wrap: wrap;
    padding: var(--s-2);
    border-radius: var(--r-container);
  }
  .links {
    width: 100%;
    overflow-x: auto;
    flex-wrap: nowrap;
    -webkit-overflow-scrolling: touch;
    scrollbar-width: none;
  }
  .links::-webkit-scrollbar { display: none; }
  .user { width: 100%; justify-content: flex-end; }
}
</style>
