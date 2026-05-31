// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-05-01',
  devtools: { enabled: true },

  modules: ['@nuxtjs/supabase'],

  // @nuxtjs/supabase 預設會把所有頁面導去 /login;
  // 前台 storefront (anon 預約) 必須關掉自動 redirect,改由 admin middleware 自行守衛。
  supabase: {
    redirect: false,
  },

  runtimeConfig: {
    public: {
      // 可供前端讀取的店家預設 tenant slug, 之後改成子網域解析
      defaultTenantSlug: process.env.NUXT_PUBLIC_DEFAULT_TENANT_SLUG ?? '',
    },
  },

  typescript: {
    strict: true,
  },
})
