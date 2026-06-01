-- =============================================================
-- 0008 — 服務圖 + 設計師作品集
-- =============================================================
-- 目標:
--   1. services.image_path: 每個服務的代表圖 (1 張)
--   2. staff_portfolio: 設計師作品集 (多張)
--   3. Supabase Storage bucket 'portfolio' (public read, tenant-scoped write)
--
-- Storage 路徑慣例:
--   <tenant_id>/services/<service_id>/main.<ext>
--   <tenant_id>/staff/<staff_id>/<random>.<ext>
-- =============================================================

-- ---------- DB schema ----------
alter table public.services add column image_path text;

create table public.staff_portfolio (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  storage_path  text not null,
  caption       text,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);
create index on public.staff_portfolio(tenant_id, staff_id, sort_order);

alter table public.staff_portfolio enable row level security;

-- 後台老闆 CRUD (RLS 依 tenant_id 限定)
create policy tenant_isolation on public.staff_portfolio
  for all to authenticated
  using (tenant_id in (select public.current_tenant_ids()))
  with check (tenant_id in (select public.current_tenant_ids()));

-- 前台 (anon) 可讀公開作品 — 屬於啟用中設計師的作品才開放
create policy public_read_staff_portfolio on public.staff_portfolio
  for select to anon
  using (
    exists (
      select 1 from public.staff s
      where s.id = staff_portfolio.staff_id and s.is_active = true
    )
  );

-- Grants (對齊 0003 慣例)
grant select, insert, update, delete on public.staff_portfolio to authenticated;
grant select on public.staff_portfolio to anon;
grant select, insert, update, delete on public.staff_portfolio to service_role;

-- ---------- Supabase Storage ----------
-- 建 public bucket
insert into storage.buckets (id, name, public)
values ('portfolio', 'portfolio', true)
on conflict (id) do update set public = excluded.public;

-- 移除可能殘留的舊 policies (idempotent)
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portfolio_public_read')
  then drop policy portfolio_public_read on storage.objects; end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portfolio_tenant_insert')
  then drop policy portfolio_tenant_insert on storage.objects; end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portfolio_tenant_update')
  then drop policy portfolio_tenant_update on storage.objects; end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portfolio_tenant_delete')
  then drop policy portfolio_tenant_delete on storage.objects; end if;
end $$;

-- 公開讀
create policy portfolio_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'portfolio');

-- 老闆寫 (僅限自己 tenant 的資料夾)
-- storage.foldername(name) 把 'aa/bb/cc.jpg' 拆成 {aa, bb}
create policy portfolio_tenant_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'portfolio'
    and (storage.foldername(name))[1]::uuid in (select public.current_tenant_ids())
  );

create policy portfolio_tenant_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'portfolio'
    and (storage.foldername(name))[1]::uuid in (select public.current_tenant_ids())
  );

create policy portfolio_tenant_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'portfolio'
    and (storage.foldername(name))[1]::uuid in (select public.current_tenant_ids())
  );
