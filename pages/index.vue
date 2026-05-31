<script setup lang="ts">
definePageMeta({ layout: 'storefront' })
</script>

<template>
  <main style="max-width: 640px; margin: 4rem auto; font-family: system-ui; line-height: 1.6;">
    <h1>美業預約平台</h1>
    <p>scaffolding 已就緒。下一步：完成 Supabase migration、後台登入、服務/員工 CRUD、前台 /book 流程。</p>
    <p>
      <NuxtLink to="/book">→ 前台預約 demo</NuxtLink> ｜
      <NuxtLink to="/admin">→ 後台</NuxtLink>
    </p>
  </main>
</template>
