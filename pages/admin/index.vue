<script setup lang="ts">
// 後台首頁 (之後會放日曆); 先放一個基本的歡迎 + 我的店家資訊。
definePageMeta({
  middleware: 'auth',
  layout: 'admin',
})

const supabase = useSupabaseClient()
const user = useSupabaseUser()

// 透過 RLS,select 會自動限制成「我屬於的 tenants」
const { data: myTenants, refresh } = await useAsyncData(
  'my-tenants',
  async () => {
    const { data, error } = await supabase
      .from('tenants')
      .select('id, name, slug, timezone')
    if (error) throw error
    return data
  },
)
</script>

<template>
  <div>
    <h1>後台</h1>

    <section class="card">
      <h2>登入身分</h2>
      <p>{{ user?.email }}</p>
      <p class="muted">user.id: <code>{{ user?.id }}</code></p>
    </section>

    <section class="card">
      <h2>我管理的店家 (透過 tenant_members 解析)</h2>
      <p v-if="!myTenants?.length" class="muted">
        尚未綁定店家。請告訴開發者用你的 email 跑 seed SQL,把你加進 tenant_members。
      </p>
      <ul v-else>
        <li v-for="t in myTenants" :key="t.id">
          <strong>{{ t.name }}</strong> <code>({{ t.slug }})</code> · TZ: {{ t.timezone }}
        </li>
      </ul>
    </section>

    <section class="card">
      <h2>下一步</h2>
      <p>之後這裡會放日曆。先去:</p>
      <ul>
        <li><NuxtLink to="/admin/services">服務管理</NuxtLink></li>
        <li><NuxtLink to="/admin/staff">員工 / 班表管理</NuxtLink></li>
      </ul>
    </section>
  </div>
</template>

<style scoped>
.card {
  background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px;
  margin-bottom: 1rem;
}
.card h2 { font-size: 1rem; margin: 0 0 0.5rem; }
.muted { color: #888; font-size: 0.9rem; }
code { background: #f4f4f4; padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.85em; }
</style>
