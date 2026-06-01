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
