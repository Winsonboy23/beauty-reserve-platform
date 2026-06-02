<script setup lang="ts">
definePageMeta({ layout: 'storefront' })

const tenant = useState<{ id: string; name: string; slug: string } | null>('tenant')

useSeoMeta({
  title: () => tenant.value
    ? `${tenant.value.name} · 線上預約`
    : '美業預約平台 — 你的品牌專屬預約頁',
  description: () => tenant.value
    ? `${tenant.value.name} 提供線上自助預約。立即查詢可用時段並完成預約。`
    : '為美業店家打造可被 Google 收錄的品牌預約頁。',
  ogType: 'website',
})
</script>

<template>
  <main class="page">
    <!-- 店家頁 -->
    <template v-if="tenant">
      <section class="hero glass-strong">
        <h1 class="lg-largetitle">{{ tenant.name }}</h1>
        <p class="lg-callout lg-muted">線上 24 小時自助預約,不用打電話。</p>
        <div class="cta-row">
          <NuxtLink to="/book" class="lg-btn lg-btn-filled cta">立即預約</NuxtLink>
          <NuxtLink to="/staff" class="lg-btn lg-btn-secondary cta">看設計師作品</NuxtLink>
        </div>
      </section>
    </template>

    <!-- 平台 landing -->
    <template v-else>
      <section class="hero glass-strong">
        <h1 class="lg-largetitle">美業預約平台</h1>
        <p class="lg-title3 lg-muted lead">
          為美業店家打造可被 Google 搜尋到的<br>品牌專屬預約頁。
        </p>
        <NuxtLink to="/admin/login" class="lg-btn lg-btn-filled cta">店家登入</NuxtLink>
      </section>

      <section class="features">
        <div class="feature glass">
          <h3 class="lg-headline">商家專屬子網域</h3>
          <p class="lg-subhead">yourshop.example.com · 被 Google 收錄</p>
        </div>
        <div class="feature glass">
          <h3 class="lg-headline">預約並發保護</h3>
          <p class="lg-subhead">DB 層擋同時段重疊,不會雙重爽約</p>
        </div>
        <div class="feature glass">
          <h3 class="lg-headline">自助改期 / 取消</h3>
          <p class="lg-subhead">客人收到專屬連結,自行管理</p>
        </div>
        <div class="feature glass">
          <h3 class="lg-headline">人工轉帳訂金</h3>
          <p class="lg-subhead">平台不抽成,直接進你的帳戶</p>
        </div>
      </section>
    </template>
  </main>
</template>

<style scoped>
.page {
  max-width: 760px;
  margin: var(--s-7) auto;
  padding: 0 var(--s-4);
  display: flex; flex-direction: column; gap: var(--s-5);
}
.hero {
  padding: var(--s-7) var(--s-5);
  text-align: center;
  display: flex; flex-direction: column; align-items: center; gap: var(--s-3);
  border-radius: var(--r-container);
}
.hero h1 { margin: 0; }
.lead { margin: 0; max-width: 460px; }
.cta { padding: 14px 32px; font-size: var(--t-headline); }
.cta-row { display: flex; gap: var(--s-2); flex-wrap: wrap; justify-content: center; margin-top: var(--s-3); }

.features {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
  gap: var(--s-3);
}
.feature {
  padding: var(--s-4);
  border-radius: var(--r-card);
  display: flex; flex-direction: column; gap: var(--s-1);
}
.feature h3 { margin: 0; }
.feature p { margin: 0; }
</style>
