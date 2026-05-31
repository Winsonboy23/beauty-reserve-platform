-- =============================================================
-- DEMO SEED — 建立示範店家並把指定 email 設為 owner
-- =============================================================
-- 使用前提:
--   1. 該 email 已經在 Supabase Auth (Dashboard → Authentication → Users)
--      用 sign-up / invite 建立過。
--   2. .env 的 NUXT_PUBLIC_DEFAULT_TENANT_SLUG 與下方 slug 一致 (預設 'demo-shop')。
--
-- 使用方式: 在 Supabase SQL Editor 改 :owner_email 後 Run。
-- =============================================================

-- ▶ 改這裡: 填你註冊後台用的 email
\set owner_email '\'YOUR_EMAIL_HERE\''

do $$
declare
  v_owner_id uuid;
  v_tenant_id uuid;
begin
  -- 1) 從 auth.users 查 user_id
  select id into v_owner_id from auth.users where email = :owner_email;
  if v_owner_id is null then
    raise exception 'auth user with email % not found, please sign up in /admin/login first', :owner_email;
  end if;

  -- 2) 建立示範店家 (slug 對齊 .env 預設值,前台才找得到)
  insert into public.tenants (name, slug, timezone, plan)
  values ('示範美髮沙龍', 'demo-shop', 'Asia/Taipei', 'free')
  on conflict (slug) do update set name = excluded.name
  returning id into v_tenant_id;

  -- 3) 綁定 owner
  insert into public.tenant_members (tenant_id, user_id, role)
  values (v_tenant_id, v_owner_id, 'owner')
  on conflict (tenant_id, user_id) do update set role = excluded.role;

  -- 4) 建立預設訂閱 (trialing 14 天)
  insert into public.subscriptions (tenant_id, plan, status, trial_ends_at)
  values (v_tenant_id, 'free', 'trialing', now() + interval '14 days')
  on conflict (tenant_id) do nothing;

  raise notice 'OK: tenant_id=%, owner_id=%', v_tenant_id, v_owner_id;
end $$;
