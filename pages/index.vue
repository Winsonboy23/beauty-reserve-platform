<script setup lang="ts">
definePageMeta({ layout: 'storefront' })

const tenant = useState<{ id: string; name: string; slug: string } | null>('tenant')

useSeoMeta({
  title: () => tenant.value
    ? `${tenant.value.name} · 線上預約`
    : '美業預約平台 — 你的品牌專屬預約頁',
  description: () => tenant.value
    ? `${tenant.value.name} 提供線上自助預約。立即查詢可用時段並完成預約。`
    : '為美業店家打造可被 Google 收錄的品牌預約頁。商家專屬子網域、自訂內容、不再漏單爽約。',
  ogType: 'website',
})
</script>

<template>
  <main class="page">
    <!-- 有 tenant: 店家品牌頁 -->
    <template v-if="tenant">
      <h1>{{ tenant.name }}</h1>
      <p class="lead">線上 24 小時自助預約,不用打電話。</p>
      <NuxtLink to="/book" class="cta">立即預約 →</NuxtLink>
    </template>

    <!-- 無 tenant: 平台 landing -->
    <template v-else>
      <h1>美業預約平台</h1>
      <p class="lead">
        為美業店家打造可被 Google 搜尋到的品牌預約頁。
        子網域、自訂內容、客人 24 小時自助預約。
      </p>
      <ul class="features">
        <li>✓ 商家專屬子網域 (yourshop.example.com)</li>
        <li>✓ 預約並發保護 — 不會有重複爽約</li>
        <li>✓ 自助改期 / 取消連結</li>
        <li>✓ 員工排班 + 例外日 + 多人預約</li>
        <li>✓ 訂金人工轉帳 / 平台不抽成</li>
      </ul>
      <p>
        <NuxtLink to="/admin/login" class="cta secondary">店家後台 →</NuxtLink>
      </p>
    </template>
  </main>
</template>

<style scoped>
.page { max-width: 640px; margin: 4rem auto; padding: 0 1.5rem; font-family: system-ui; line-height: 1.6; }
h1 { font-size: 2rem; margin: 0 0 0.5rem; }
.lead { color: #555; font-size: 1.05rem; }
.features { color: #444; padding-left: 1.2rem; line-height: 2; }
.cta {
  display: inline-block; margin-top: 1rem; padding: 0.7rem 1.4rem;
  background: #1a1a1a; color: #fff; border-radius: 6px; text-decoration: none; font-weight: 500;
}
.cta.secondary { background: #f4f4f4; color: #1a1a1a; border: 1px solid #ddd; }
</style>
