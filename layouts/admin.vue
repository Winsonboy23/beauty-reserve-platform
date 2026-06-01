<script setup lang="ts">
// 後台 layout: 需登入 (middleware/auth.ts 守衛 /admin/* 路由)。
// 第一輪只放 placeholder, CRUD 畫面之後再補。
const user = useSupabaseUser()
const supabase = useSupabaseClient()

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
        <NuxtLink to="/admin">日曆</NuxtLink>
        <NuxtLink to="/admin/services">服務</NuxtLink>
        <NuxtLink to="/admin/staff">員工</NuxtLink>
        <NuxtLink to="/admin/settings">設定</NuxtLink>
        <span v-if="user" class="user">{{ user.email }} <button @click="signOut">登出</button></span>
      </nav>
    </header>
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
.admin-header nav { display: flex; gap: 1rem; align-items: center; flex: 1; }
.admin-header nav a.router-link-active { font-weight: bold; }
.user { margin-left: auto; display: flex; gap: 0.5rem; align-items: center; }
.admin-main { padding: 1.5rem; }
</style>
