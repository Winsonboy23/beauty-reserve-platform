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
    <form class="lg-card card" @submit.prevent="submit">
      <header class="head">
        <h1 class="lg-title1">{{ mode === 'signin' ? '登入' : '註冊' }}</h1>
        <p class="lg-subhead">店家後台</p>
      </header>

      <div class="fields">
        <label class="lg-field">
          <span class="lg-field-label">Email</span>
          <input v-model="email" type="email" required autocomplete="email" class="lg-input" />
        </label>
        <label class="lg-field">
          <span class="lg-field-label">密碼</span>
          <input v-model="password" type="password" required minlength="6"
                 autocomplete="current-password" class="lg-input" />
        </label>
      </div>

      <button :disabled="loading" type="submit" class="lg-btn lg-btn-filled submit-btn">
        {{ loading ? '處理中…' : mode === 'signin' ? '登入' : '註冊' }}
      </button>

      <p class="switch lg-footnote">
        <template v-if="mode === 'signin'">
          還沒帳號? <a href="#" @click.prevent="mode = 'signup'">註冊</a>
        </template>
        <template v-else>
          已有帳號? <a href="#" @click.prevent="mode = 'signin'">登入</a>
        </template>
      </p>

      <p v-if="errMsg" class="lg-pill lg-pill-danger msg">{{ errMsg }}</p>
      <p v-if="okMsg" class="lg-pill lg-pill-success msg">{{ okMsg }}</p>
    </form>
  </div>
</template>

<style scoped>
.wrap {
  min-height: 100vh;
  display: flex; align-items: center; justify-content: center;
  padding: var(--s-4);
}
.card {
  width: 100%; max-width: 380px;
  display: flex; flex-direction: column; gap: var(--s-4);
  padding: var(--s-5);
}
.head { text-align: center; }
.head h1 { margin: 0 0 4px; }
.fields { display: flex; flex-direction: column; gap: var(--s-3); }
.submit-btn { padding: 14px; font-size: var(--t-headline); }
.switch { text-align: center; margin: 0; }
.msg { align-self: flex-start; max-width: 100%; white-space: normal; }
</style>
