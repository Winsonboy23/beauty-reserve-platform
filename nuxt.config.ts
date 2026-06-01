// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-05-01',
  devtools: { enabled: true },

  modules: ['@nuxtjs/supabase'],

  css: ['~/assets/css/liquid-glass.css'],

  // @nuxtjs/supabase 預設會把所有頁面導去 /login;
  // 前台 storefront (anon 預約) 必須關掉自動 redirect,改由 admin middleware 自行守衛。
  supabase: {
    redirect: false,
  },

  runtimeConfig: {
    // server-only (絕不暴露到 client bundle)
    resendApiKey: process.env.RESEND_API_KEY ?? '',
    emailFrom: process.env.EMAIL_FROM ?? 'onboarding@resend.dev',
    supabaseServiceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY ?? '',

    public: {
      // 可供前端讀取的店家預設 tenant slug, 之後改成子網域解析
      defaultTenantSlug: process.env.NUXT_PUBLIC_DEFAULT_TENANT_SLUG ?? '',
      // 與 @nuxtjs/supabase 共用值,讓 server route 也能拿到
      supabaseUrl: process.env.SUPABASE_URL ?? '',
      supabaseKey: process.env.SUPABASE_KEY ?? '',
    },
  },

  typescript: {
    strict: true,
  },

  // 允許子網域開發 (lvh.me 是公開的 wildcard DNS → 127.0.0.1);
  // Vite 7 預設只放行 localhost,得手動加。
  vite: {
    server: {
      allowedHosts: ['.lvh.me', 'localhost'],
    },
  },
})
