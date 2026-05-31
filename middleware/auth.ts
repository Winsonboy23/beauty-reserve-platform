// /admin/* 路由守衛: 未登入導去 /admin/login。
// 在頁面用 definePageMeta({ middleware: 'auth', layout: 'admin' })
export default defineNuxtRouteMiddleware((to) => {
  const user = useSupabaseUser()
  if (!user.value && to.path !== '/admin/login') {
    return navigateTo('/admin/login')
  }
})
