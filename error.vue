<script setup lang="ts">
const props = defineProps<{
  error: {
    statusCode: number
    statusMessage?: string
    message?: string
    data?: { hint?: string }
  }
}>()

const isNotFound = computed(() => props.error.statusCode === 404)

function goHome() {
  clearError({ redirect: '/' })
}
</script>

<template>
  <main class="page">
    <h1>{{ isNotFound ? '404' : error.statusCode }}</h1>
    <h2>{{ error.statusMessage || (isNotFound ? '找不到頁面' : '發生錯誤') }}</h2>
    <p v-if="error.data?.hint" class="muted">{{ error.data.hint }}</p>
    <button @click="goHome">回首頁</button>
  </main>
</template>

<style scoped>
.page {
  max-width: 480px; margin: 6rem auto; padding: 0 1.5rem;
  text-align: center; font-family: system-ui; line-height: 1.6;
}
h1 { font-size: 4rem; margin: 0; color: #888; font-weight: 300; }
h2 { font-size: 1.4rem; margin: 0.5rem 0 1rem; }
.muted { color: #888; }
button {
  margin-top: 1.5rem; padding: 0.6rem 1.4rem; border: 0; border-radius: 4px;
  background: #1a1a1a; color: #fff; cursor: pointer; font-size: 1rem;
}
</style>
