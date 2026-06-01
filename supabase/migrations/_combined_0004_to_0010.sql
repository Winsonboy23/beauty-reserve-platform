-- =============================================================
-- 合併 migration 0004 ~ 0010 — 一次貼到 SQL Editor 跑
-- 注意:先到 Dashboard → Database → Extensions 啟用 pg_cron (不啟用 0006 那段會 fail,但其他都會繼續)
-- 不要重複跑
-- =============================================================

-- ───────────────────────────── 0004_tenant_bank_info.sql ─────────────────────────────
-- =============================================================
-- 0004 — 店家銀行帳號 (轉帳訂金用)
-- =============================================================
-- v1 金流走「人工轉帳」: 客人按下預約後,系統需告知要匯到哪。
-- 帳號資訊存在 tenants 表上,前台預約成功頁讀取顯示。
--
-- 注意法遵: 此欄位儲存的是「店家自己的」銀行帳號 (情況 A,平台不經手金流);
-- 客人匯款直接進店家帳戶,平台只是把資訊顯示給客人。
-- =============================================================

alter table public.tenants
  add column bank_name            text,         -- 例: 國泰世華 / 中信 (含分行更佳)
  add column bank_account_no      text,         -- 帳號數字
  add column bank_account_holder  text,         -- 戶名
  add column bank_transfer_note   text;         -- 額外說明 (給客人看的提示)

-- anon 已在 0003 的 public_read_tenants policy 允許讀取 tenants;
-- 這幾個欄位會跟著被公開讀到,這是預期行為 (預約頁需要)。
-- 若未來想限縮敏感欄位,可改用 SECURITY DEFINER RPC 回傳 tenant 公開資訊。

-- ───────────────────────────── 0005_blacklist.sql ─────────────────────────────
-- =============================================================
-- 0005 — 黑名單 (防爽約)
-- =============================================================
-- members 加 is_blacklisted, 預約 RPC 在 upsert 前先檢查同店電話是否在黑名單,
-- 是則拒絕。錯誤代碼 'member_blacklisted' 給前端做友善訊息。
--
-- 設計考量:
-- 1. 黑名單在 tenant 層級 (同一個客人在 A 店黑名單,B 店仍可預約)。
-- 2. 不公開把客人標為黑名單的事實; 前端只顯示「請聯絡店家」。
-- 3. 老闆手動切換,不自動 (避免誤判)。
-- =============================================================

alter table public.members
  add column is_blacklisted boolean not null default false;

create index on public.members(tenant_id, phone) where is_blacklisted;

-- ---------- 重寫 create_booking ----------
-- 重複大部分 0002 邏輯, 在 upsert member 前多一道黑名單檢查。
create or replace function public.create_booking(
  p_tenant_id      uuid,
  p_staff_id       uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_booking_id uuid;
begin
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  -- 黑名單檢查 (在 upsert member 之前)
  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold)
    returning id into v_booking_id;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  return v_booking_id;
end $$;

-- ---------- 重寫 create_booking_any ----------
create or replace function public.create_booking_any(
  p_tenant_id      uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null,
  out booking_id   uuid,
  out staff_id     uuid
)
language plpgsql security definer set search_path = public as $$
declare
  v_tz       text;
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_local_date date;
  v_cand     uuid;
begin
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  select timezone into v_tz from tenants where id = p_tenant_id;
  v_local_date := (p_start_at at time zone v_tz)::date;

  -- 黑名單檢查
  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  for v_cand in
    select s.id
    from staff s
    join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
    where s.tenant_id = p_tenant_id
      and s.is_active = true
      and public.is_slot_available(s.id, p_start_at, v_duration)
    order by (
      select count(*) from bookings b
      where b.staff_id = s.id and b.status <> 'cancelled'
        and (b.start_at at time zone v_tz)::date = v_local_date
    ) asc, random()
  loop
    begin
      insert into bookings (tenant_id, staff_id, service_id, member_id,
                            start_at, duration_minutes, status, note,
                            deposit_amount, deposit_status, hold_expires_at)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold)
      returning id into booking_id;

      staff_id := v_cand;
      return;
    exception when exclusion_violation then
      continue;
    end;
  end loop;

  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

-- ───────────────────────────── 0006_pg_cron_cleanup.sql ─────────────────────────────
-- =============================================================
-- 0006 — 排程 cleanup_expired_holds 每 5 分鐘跑一次
-- =============================================================
-- 前置: 必須先在 Supabase Dashboard → Database → Extensions 啟用 pg_cron。
-- (UI 上搜 'pg_cron' 切 Enable, 或下面那行 SQL 也可,
--  但建議走 UI 因為 Supabase 內部需要做額外設定)
--
-- 跑完這支後,bookings 表 hold_expires_at 過期且仍 deposit_status='pending'
-- 的預約會自動轉成 cancelled,把 slot 釋放給其他客人。
-- =============================================================

create extension if not exists pg_cron;

-- 移除舊排程 (重跑此 migration 才不會疊加)
do $$ begin
  if exists (select 1 from cron.job where jobname = 'release-holds') then
    perform cron.unschedule('release-holds');
  end if;
end $$;

-- 每 5 分鐘跑一次
select cron.schedule(
  'release-holds',
  '*/5 * * * *',
  $$ select public.cleanup_expired_holds() $$
);

-- 驗證: 查 schedule 是否存在
-- select jobname, schedule, command from cron.job where jobname = 'release-holds';

-- ───────────────────────────── 0007_manage_token.sql ─────────────────────────────
-- =============================================================
-- 0007 — 預約改期 / 取消 自助 (manage_token + 3 個 RPC)
-- =============================================================
-- 客人收到含 token 的連結 (/manage/<booking_id>?t=<token>),
-- 不需登入即可改期或取消自己的預約。token 是隨機 32-char hex。
--
-- 安全模型: token 等於密碼。誰拿到誰能改; 不外洩就 OK。
-- =============================================================

-- 1) 加欄位 (先 nullable, backfill 後再 set NOT NULL,避免歷史資料卡住)
alter table public.bookings add column manage_token text;
update public.bookings set manage_token = encode(gen_random_bytes(16), 'hex')
  where manage_token is null;
alter table public.bookings alter column manage_token set not null;
alter table public.bookings alter column manage_token
  set default encode(gen_random_bytes(16), 'hex');

create index on public.bookings(manage_token);

-- =============================================================
-- 2) 重寫 create_booking — 回傳 (booking_id, manage_token)
-- =============================================================
-- 為了與 0005 的版本保持一致 (含黑名單檢查),整個複製過來改 RETURN。
-- ★ 函式 signature 變動: 從 returns uuid 改為 returns table。
--   舊呼叫端需同步調整 (useBooking.ts)。
-- =============================================================
drop function if exists public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text);

create or replace function public.create_booking(
  p_tenant_id      uuid,
  p_staff_id       uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null
) returns table (booking_id uuid, manage_token text)
language plpgsql security definer set search_path = public as $$
declare
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_id uuid;
  v_token text;
begin
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold)
    returning id, bookings.manage_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  booking_id := v_id;
  manage_token := v_token;
  return next;
end $$;

grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text) to anon;

-- =============================================================
-- 3) 重寫 create_booking_any — 多回一個 manage_token
-- =============================================================
drop function if exists public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text);

create or replace function public.create_booking_any(
  p_tenant_id      uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null,
  out booking_id   uuid,
  out staff_id     uuid,
  out manage_token text
)
language plpgsql security definer set search_path = public as $$
declare
  v_tz       text;
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_local_date date;
  v_cand     uuid;
begin
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  select timezone into v_tz from tenants where id = p_tenant_id;
  v_local_date := (p_start_at at time zone v_tz)::date;

  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  for v_cand in
    select s.id
    from staff s
    join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
    where s.tenant_id = p_tenant_id
      and s.is_active = true
      and public.is_slot_available(s.id, p_start_at, v_duration)
    order by (
      select count(*) from bookings b
      where b.staff_id = s.id and b.status <> 'cancelled'
        and (b.start_at at time zone v_tz)::date = v_local_date
    ) asc, random()
  loop
    begin
      insert into bookings (tenant_id, staff_id, service_id, member_id,
                            start_at, duration_minutes, status, note,
                            deposit_amount, deposit_status, hold_expires_at)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold)
      returning id, bookings.manage_token into booking_id, manage_token;

      staff_id := v_cand;
      return;
    exception when exclusion_violation then
      continue;
    end;
  end loop;

  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

grant execute on function public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text) to anon;

-- =============================================================
-- 4) get_booking_for_manage — 客人載入 /manage 頁面用
-- =============================================================
create or replace function public.get_booking_for_manage(
  p_booking_id uuid,
  p_token text
) returns table (
  id uuid,
  start_at timestamptz,
  end_at timestamptz,
  status booking_status,
  duration_minutes int,
  note text,
  deposit_amount numeric,
  deposit_status deposit_status,
  hold_expires_at timestamptz,
  staff_id uuid, staff_name text,
  service_id uuid, service_name text, service_price numeric,
  tenant_id uuid, tenant_name text, tenant_timezone text,
  tenant_bank_name text, tenant_bank_account_no text,
  tenant_bank_account_holder text, tenant_bank_transfer_note text
)
language sql stable security definer set search_path = public as $$
  select
    b.id, b.start_at, b.end_at, b.status, b.duration_minutes, b.note,
    b.deposit_amount, b.deposit_status, b.hold_expires_at,
    b.staff_id, s.name,
    b.service_id, sv.name, sv.price,
    b.tenant_id, t.name, t.timezone,
    t.bank_name, t.bank_account_no, t.bank_account_holder, t.bank_transfer_note
  from bookings b
  join staff s on s.id = b.staff_id
  join services sv on sv.id = b.service_id
  join tenants t on t.id = b.tenant_id
  where b.id = p_booking_id and b.manage_token = p_token;
$$;

grant execute on function public.get_booking_for_manage(uuid, text) to anon;

-- =============================================================
-- 5) reschedule_booking — 客人改期
-- =============================================================
create or replace function public.reschedule_booking(
  p_booking_id   uuid,
  p_token        text,
  p_new_start_at timestamptz
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid;
  v_dur   int;
  v_status booking_status;
begin
  select staff_id, duration_minutes, status
    into v_staff, v_dur, v_status
  from bookings
  where id = p_booking_id and manage_token = p_token;

  if v_staff is null then
    raise exception 'booking_not_found' using errcode = 'no_data_found';
  end if;
  if v_status in ('cancelled', 'completed', 'no_show') then
    raise exception 'booking_not_modifiable' using errcode = 'check_violation';
  end if;
  if not public.is_slot_available(v_staff, p_new_start_at, v_dur) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  begin
    update bookings set start_at = p_new_start_at where id = p_booking_id;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;
end $$;

grant execute on function public.reschedule_booking(uuid, text, timestamptz) to anon;

-- =============================================================
-- 6) cancel_booking_by_token — 客人取消
-- =============================================================
create or replace function public.cancel_booking_by_token(
  p_booking_id uuid,
  p_token      text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_status booking_status;
begin
  select status into v_status
  from bookings
  where id = p_booking_id and manage_token = p_token;

  if v_status is null then
    raise exception 'booking_not_found' using errcode = 'no_data_found';
  end if;
  if v_status in ('cancelled', 'completed', 'no_show') then
    raise exception 'booking_not_modifiable' using errcode = 'check_violation';
  end if;

  update bookings set status = 'cancelled' where id = p_booking_id;
end $$;

grant execute on function public.cancel_booking_by_token(uuid, text) to anon;

-- ───────────────────────────── 0008_portfolio.sql ─────────────────────────────
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

-- ───────────────────────────── 0009_plan_limits.sql ─────────────────────────────
-- =============================================================
-- 0009 — 方案限制執行 (Plan Limits Enforcement)
-- =============================================================
-- 設計:
--   1. plan_limits(plan)        — 純資料,回傳該方案的硬性上限
--   2. tenant_usage(tenant_id)  — 即時計算當下用量
--   3. plan_status(tenant_id)   — 合併兩者,前端 1 次拿完
--   4. create_booking 加 month-booking 上限檢查
--   5. auto_downgrade_trials()  — 試用到期 → 自動降級為 free
--                                (排程在後面 schedule cron job)
--
-- 上限規則 (對齊 features.md v3):
--   免費: 預約 15/月, 會員 50, 服務 5, 員工 1, 不可訂金, 不可子網域
--   基本: 無限筆數/會員/服務, 員工 2, 可訂金, 可子網域
--   專業: 全部無限
--
-- -1 表示「無上限」(不檢查)。
-- =============================================================

create or replace function public.plan_limits(p_plan plan_tier)
returns table (
  bookings_per_month     int,
  services               int,
  staff                  int,
  members                int,
  can_deposit            boolean,
  can_subdomain          boolean,
  line_msgs_per_month    int
)
language sql immutable as $$
  select
    case p_plan when 'free' then 15  else -1 end,
    case p_plan when 'free' then 5   else -1 end,
    case p_plan when 'free' then 1
                 when 'basic' then 2
                 else -1 end,
    case p_plan when 'free' then 50  else -1 end,
    case p_plan when 'free' then false else true  end,
    case p_plan when 'free' then false else true  end,
    case p_plan when 'free'  then 0
                 when 'basic' then 200
                 when 'pro'   then 1000
                 end;
$$;

-- 取出某 tenant 當前用量
create or replace function public.tenant_usage(p_tenant_id uuid)
returns table (
  plan                 plan_tier,
  status               subscription_status,
  trial_ends_at        timestamptz,
  bookings_this_month  int,
  services             int,
  staff                int,
  members              int
)
language sql stable security definer set search_path = public as $$
  with t as (
    select id, timezone from public.tenants where id = p_tenant_id
  ),
  s as (
    select sub.plan, sub.status, sub.trial_ends_at
    from public.subscriptions sub where sub.tenant_id = p_tenant_id
  ),
  -- 試用中以「專業」上限計算(讓他 14 天爽用); 結束後跟 plan 走
  effective as (
    select case when s.status = 'trialing' and s.trial_ends_at > now()
                then 'pro'::plan_tier else s.plan end as plan,
           s.status, s.trial_ends_at
    from s
  )
  select
    e.plan, e.status, e.trial_ends_at,
    (select count(*)::int from public.bookings b, t
       where b.tenant_id = p_tenant_id and b.status <> 'cancelled'
         and (b.start_at at time zone t.timezone) >=
             date_trunc('month', (now() at time zone t.timezone))),
    (select count(*)::int from public.services
       where tenant_id = p_tenant_id and is_active = true),
    (select count(*)::int from public.staff
       where tenant_id = p_tenant_id and is_active = true),
    (select count(*)::int from public.members where tenant_id = p_tenant_id)
  from effective e;
$$;

grant execute on function public.tenant_usage(uuid) to authenticated;

-- 一次撈完前端要的所有東西
create or replace function public.plan_status(p_tenant_id uuid)
returns json
language sql stable security definer set search_path = public as $$
  with u as (select * from public.tenant_usage(p_tenant_id) limit 1),
       l as (select * from public.plan_limits((select plan from u)) limit 1)
  select json_build_object(
    'plan', u.plan,
    'status', u.status,
    'trial_ends_at', u.trial_ends_at,
    'used', json_build_object(
      'bookings_this_month', u.bookings_this_month,
      'services', u.services,
      'staff', u.staff,
      'members', u.members
    ),
    'limits', json_build_object(
      'bookings_per_month', l.bookings_per_month,
      'services', l.services,
      'staff', l.staff,
      'members', l.members,
      'can_deposit', l.can_deposit,
      'can_subdomain', l.can_subdomain,
      'line_msgs_per_month', l.line_msgs_per_month
    )
  )
  from u, l;
$$;

grant execute on function public.plan_status(uuid) to authenticated;

-- =============================================================
-- create_booking 重寫 — 加月預約上限檢查
-- =============================================================
-- 重新覆蓋 0007 的版本; 邏輯一樣只多一段 plan-limit 檢查。
-- 拋 'plan_limit_exceeded' (errcode 'check_violation') 讓前端轉訊息。
-- =============================================================
drop function if exists public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text);

create or replace function public.create_booking(
  p_tenant_id      uuid,
  p_staff_id       uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null
) returns table (booking_id uuid, manage_token text)
language plpgsql security definer set search_path = public as $$
declare
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_id uuid;
  v_token text;
  v_book_limit int;
  v_used int;
begin
  -- 1) 方案限制: 月預約筆數
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  -- 2) 服務驗證
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  -- 3) 訂金功能受方案限制 (free 不可收訂金 → 強制 0)
  if v_deposit > 0 and not (select can_deposit from public.plan_limits(
       (select plan from public.tenant_usage(p_tenant_id)))) then
    v_deposit := 0;
  end if;

  -- 4) 黑名單
  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold)
    returning id, bookings.manage_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  booking_id := v_id;
  manage_token := v_token;
  return next;
end $$;

grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text) to anon;

-- =============================================================
-- create_booking_any 同步加 plan-limit + can_deposit
-- =============================================================
drop function if exists public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text);

create or replace function public.create_booking_any(
  p_tenant_id      uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null,
  out booking_id   uuid,
  out staff_id     uuid,
  out manage_token text
)
language plpgsql security definer set search_path = public as $$
declare
  v_tz       text;
  v_duration int;
  v_deposit  numeric(10,2);
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_local_date date;
  v_cand     uuid;
  v_book_limit int;
  v_used int;
begin
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  select timezone into v_tz from tenants where id = p_tenant_id;
  v_local_date := (p_start_at at time zone v_tz)::date;

  if v_deposit > 0 and not (select can_deposit from public.plan_limits(
       (select plan from public.tenant_usage(p_tenant_id)))) then
    v_deposit := 0;
  end if;

  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status
                       else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours'
                       else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  for v_cand in
    select s.id from staff s
    join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
    where s.tenant_id = p_tenant_id and s.is_active = true
      and public.is_slot_available(s.id, p_start_at, v_duration)
    order by (
      select count(*) from bookings b
      where b.staff_id = s.id and b.status <> 'cancelled'
        and (b.start_at at time zone v_tz)::date = v_local_date
    ) asc, random()
  loop
    begin
      insert into bookings (tenant_id, staff_id, service_id, member_id,
                            start_at, duration_minutes, status, note,
                            deposit_amount, deposit_status, hold_expires_at)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold)
      returning id, bookings.manage_token into booking_id, manage_token;

      staff_id := v_cand;
      return;
    exception when exclusion_violation then
      continue;
    end;
  end loop;

  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

grant execute on function public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text) to anon;

-- =============================================================
-- 試用到期自動降級 (每天跑一次,排在 cleanup_expired_holds 旁邊)
-- =============================================================
create or replace function public.auto_downgrade_trials()
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with upd as (
    update subscriptions
    set status = 'active', plan = 'free'
    where status = 'trialing' and trial_ends_at < now()
    returning 1
  )
  select count(*) into v_n from upd;
  return v_n;
end $$;

-- 排程 (僅當 pg_cron 已啟用時才會成功; 沒啟用就跳過)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'auto-downgrade-trials') then
      perform cron.unschedule('auto-downgrade-trials');
    end if;
    perform cron.schedule(
      'auto-downgrade-trials',
      '0 3 * * *',  -- 每天 3:00 UTC (台北 11:00)
      $cmd$ select public.auto_downgrade_trials() $cmd$
    );
  end if;
end $$;

-- ───────────────────────────── 0010_tenant_slug_format.sql ─────────────────────────────
-- =============================================================
-- 0010 — tenants.slug 格式約束
-- =============================================================
-- 為了當子網域用,slug 必須:
--   1. 3–30 字
--   2. 只能小寫字母、數字、連字號
--   3. 不能以 hyphen 開頭/結尾
--
-- 保留字 (admin/api/www/...) 由 application 層擋 (在 settings 頁加檢查),
-- DB 不擋是因為現有 demo-shop 已存在,加 reserved 清單會與保留字升級難。
-- =============================================================

alter table public.tenants
  add constraint tenant_slug_format
  check (
    char_length(slug) between 3 and 30
    and slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
  );

