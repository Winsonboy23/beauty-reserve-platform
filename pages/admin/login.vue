<script setup lang="ts">
// 後台登入 / 註冊頁。
// 為了 MVP demo 同時開放 sign-up; 之後正式上線改為「邀請制 / 註冊 → 自動建立 tenant」流程。
definePageMeta({ layout: false })

const supabase = useSupabaseClient()
const user = useSupabaseUser()

const mode = ref<'signin' | 'signup'>('signin')
const email = ref('')
const password = ref('')
const loading = ref(false)
const errMsg = ref<string | null>(null)
const okMsg = ref<string | null>(null)

// 已登入直接導去後台首頁
watchEffect(() => {
  if (user.value) navigateTo('/admin')
})

async function submit() {
  errMsg.value = null
  okMsg.value = null
  loading.value = true
  try {
    if (mode.value === 'signin') {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.value,
        password: password.value,
      })
      if (error) throw error
      // user watcher 會自動 navigate
    } else {
      const { error } = await supabase.auth.signUp({
        email: email.value,
        password: password.value,
      })
      if (error) throw error
      okMsg.value = '註冊成功!如果 Supabase Auth 有開 email 驗證,請去信箱收信。然後告訴開發者用此 email 跑 seed SQL 取得店家綁定。'
    }
  } catch (e: any) {
    errMsg.value = e?.message ?? '登入/註冊失敗'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-wrap">
    <form class="login-card" @submit.prevent="submit">
      <h1>後台{{ mode === 'signin' ? '登入' : '註冊' }}</h1>

      <label>Email
        <input v-model="email" type="email" required autocomplete="email" />
      </label>
      <label>密碼
        <input v-model="password" type="password" required minlength="6" autocomplete="current-password" />
      </label>

      <button :disabled="loading" type="submit">
        {{ loading ? '處理中…' : mode === 'signin' ? '登入' : '註冊' }}
      </button>

      <p class="switch">
        <template v-if="mode === 'signin'">
          還沒帳號? <a href="#" @click.prevent="mode = 'signup'">註冊</a>
        </template>
        <template v-else>
          已有帳號? <a href="#" @click.prevent="mode = 'signin'">登入</a>
        </template>
      </p>

      <p v-if="errMsg" class="err">{{ errMsg }}</p>
      <p v-if="okMsg" class="ok">{{ okMsg }}</p>
    </form>
  </div>
</template>

<style scoped>
.login-wrap {
  min-height: 100vh; display: flex; align-items: center; justify-content: center;
  background: #fafafa; font-family: system-ui;
}
.login-card {
  width: 100%; max-width: 360px; padding: 2rem;
  background: #fff; border: 1px solid #eee; border-radius: 8px;
  display: flex; flex-direction: column; gap: 0.9rem;
}
.login-card h1 { font-size: 1.4rem; margin: 0 0 0.5rem; }
label { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.9rem; }
input { padding: 0.55rem 0.7rem; border: 1px solid #ddd; border-radius: 4px; font-size: 1rem; }
button {
  margin-top: 0.5rem; padding: 0.65rem; border: 0; border-radius: 4px;
  background: #1a1a1a; color: #fff; font-size: 1rem; cursor: pointer;
}
button:disabled { opacity: 0.6; cursor: not-allowed; }
.switch { font-size: 0.85rem; color: #555; text-align: center; margin: 0; }
.err { color: #c0392b; font-size: 0.85rem; margin: 0; }
.ok  { color: #1a7a3a; font-size: 0.85rem; margin: 0; }
</style>
