<script setup lang="ts">
// 前台 (消費者) layout: SSR-friendly, 不強制登入。
// tenant 解析在 middleware/tenant.global.ts 完成,放進 useState('tenant') 供頁面取用。
</script>

<template>
  <div class="storefront">
    <slot />
  </div>
</template>

<style>
body { margin: 0; background: #fafafa; color: #1a1a1a; }
.storefront { min-height: 100vh; }
</style>
