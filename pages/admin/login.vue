<script setup lang="ts">
definePageMeta({ layout: false })

const supabase = useSupabaseClient()
const user = useSupabaseUser()

const mode = ref<'signin' | 'signup'>('signin')
const email = ref('')
const password = ref('')
const loading = ref(false)
const errMsg = ref<string | null>(null)
const okMsg = ref<string | null>(null)

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
        email: email.value, password: password.value,
      })
      if (error) throw error
    } else {
      const { error } = await supabase.auth.signUp({
        email: email.value, password: password.value,
      })
      if (error) throw error
      okMsg.value = '註冊成功!如需驗證 email,請去信箱收信。'
    }
  } catch (e: any) {
    errMsg.value = e?.message ?? '登入 / 註冊失敗'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="wrap">
    <form class="card" @submit.prevent="submit">
      <header class="head">
        <h1>{{ mode === 'signin' ? '登入' : '註冊' }}</h1>
        <p class="muted">店家後台</p>
      </header>

      <label class="field">Email
        <input v-model="email" type="email" required autocomplete="email" />
      </label>
      <label class="field">密碼
        <input v-model="password" type="password" required minlength="6" autocomplete="current-password" />
      </label>

      <button :disabled="loading" type="submit" class="submit-btn">
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
.wrap {
  background: #f3eedd;
  min-height: 100vh;
  display: flex; align-items: center; justify-content: center;
  padding: 1rem;
}
.card {
  width: 100%; max-width: 380px;
  background: #fdfaf1;
  border: 1px solid #2b2b2b;
  border-radius: 14px;
  padding: 1.75rem;
  display: flex; flex-direction: column; gap: 0.85rem;
}
.head { text-align: center; margin-bottom: 0.5rem; }
.head h1 {
  font-family: Georgia, 'Times New Roman', serif;
  font-weight: 400; font-size: 1.8rem; letter-spacing: 0.03em;
  color: #1a1a1a; margin: 0 0 0.25rem;
}
.muted { color: #7a7570; font-size: 0.9rem; margin: 0; }
.field { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.85rem; color: #5b5b5b; }
.field input {
  background: #fff;
  border: 1px solid #d9d2bc;
  border-radius: 6px;
  padding: 0.55rem 0.7rem;
  font: inherit; font-size: 0.95rem; color: #1a1a1a;
  outline: none;
  transition: border-color 0.15s;
}
.field input:focus { border-color: #2b2b2b; }
.submit-btn {
  padding: 0.75rem;
  background: #1a1a1a; color: #fdfaf1;
  border: 0; border-radius: 6px;
  font-size: 1rem; font-weight: 500;
  cursor: pointer; font-family: inherit;
  transition: opacity 0.15s;
}
.submit-btn:hover:not(:disabled) { opacity: 0.85; }
.submit-btn:disabled { opacity: 0.4; cursor: not-allowed; }
.switch { text-align: center; font-size: 0.85rem; color: #7a7570; margin: 0; }
.switch a { color: #6b4900; text-decoration: underline; }
.err {
  background: #fdecea; color: #b71c1c;
  padding: 0.5rem 0.75rem; border-radius: 6px;
  font-size: 0.85rem; margin: 0;
}
.ok {
  background: #e8f5e9; color: #1b5e20;
  padding: 0.5rem 0.75rem; border-radius: 6px;
  font-size: 0.85rem; margin: 0;
}
</style>
