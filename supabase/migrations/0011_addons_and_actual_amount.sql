-- =============================================================
-- 0011 — 加購項目 + 現場結帳金額
-- =============================================================
-- 1. services.is_addon          : 標記某服務是「加購項目」(不是主服務,不獨立預約)
-- 2. bookings.addon_ids         : 該預約掛了哪些加購 (uuid[])
-- 3. bookings.actual_amount     : 客人到店實付金額 (現場結帳記錄,給報表用)
-- 4. 重寫 create_booking RPC:
--      - 收 p_addon_ids 參數
--      - 驗證 addon 屬於同店 + is_active + is_addon=true
--      - 計算總時長 = service.duration + sum(addons.duration)
--      - 計算總訂金 = service.deposit + sum(addons.deposit)
-- =============================================================

alter table public.services add column is_addon boolean not null default false;
create index on public.services(tenant_id) where is_addon;

alter table public.bookings add column addon_ids uuid[] not null default '{}';
alter table public.bookings add column actual_amount numeric(10,2);

-- =============================================================
-- create_booking — 收 addon_ids
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
  p_note           text default null,
  p_addon_ids      uuid[] default '{}'
) returns table (booking_id uuid, manage_token text)
language plpgsql security definer set search_path = public as $$
declare
  v_duration int;
  v_deposit  numeric(10,2);
  v_addon_minutes int := 0;
  v_addon_deposit numeric(10,2) := 0;
  v_dep_status deposit_status;
  v_hold     timestamptz;
  v_member_id uuid;
  v_blacklisted boolean;
  v_id uuid;
  v_token text;
  v_book_limit int;
  v_used int;
begin
  -- 1) 方案限制
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  -- 2) 主服務 (不可為 addon)
  select duration_minutes, coalesce(deposit_amount, 0)
    into v_duration, v_deposit
  from services
  where id = p_service_id and tenant_id = p_tenant_id
    and is_active = true and is_addon = false;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  -- 3) 設計師能做此服務
  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  -- 4) 加購驗證 + 加總時長/訂金
  --    所有 addon 必須: 同店, is_active, is_addon=true, 該設計師能做 (走 staff_services)
  if array_length(p_addon_ids, 1) > 0 then
    if exists (
         select 1 from unnest(p_addon_ids) as a(id)
         where not exists (
           select 1 from services s
           join staff_services ss on ss.service_id = s.id
           where s.id = a.id
             and s.tenant_id = p_tenant_id
             and s.is_active = true
             and s.is_addon = true
             and ss.staff_id = p_staff_id
         )
       ) then
      raise exception 'addon_invalid' using errcode = 'check_violation';
    end if;

    select coalesce(sum(duration_minutes), 0)::int,
           coalesce(sum(coalesce(deposit_amount, 0)), 0)
      into v_addon_minutes, v_addon_deposit
    from services where id = any (p_addon_ids);
  end if;

  v_duration := v_duration + v_addon_minutes;
  v_deposit  := v_deposit + v_addon_deposit;

  -- 5) 時段可用?
  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  -- 6) free 方案不收訂金
  if v_deposit > 0 and not (select can_deposit from public.plan_limits(
       (select plan from public.tenant_usage(p_tenant_id)))) then
    v_deposit := 0;
  end if;

  -- 7) 黑名單
  select is_blacklisted into v_blacklisted
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours' else null end;

  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at,
                          addon_ids)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold,
            p_addon_ids)
    returning id, bookings.manage_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  booking_id := v_id;
  manage_token := v_token;
  return next;
end $$;

grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[]) to anon;

-- =============================================================
-- create_booking_any 也要收 addon_ids
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
  p_addon_ids      uuid[] default '{}',
  out booking_id   uuid,
  out staff_id     uuid,
  out manage_token text
)
language plpgsql security definer set search_path = public as $$
declare
  v_tz       text;
  v_duration int;
  v_deposit  numeric(10,2);
  v_addon_minutes int := 0;
  v_addon_deposit numeric(10,2) := 0;
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
  where id = p_service_id and tenant_id = p_tenant_id
    and is_active = true and is_addon = false;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  -- addon 不檢查 staff (各 staff 可能不同), 只驗 tenant + active + is_addon
  if array_length(p_addon_ids, 1) > 0 then
    if exists (
         select 1 from unnest(p_addon_ids) as a(id)
         where not exists (
           select 1 from services s
           where s.id = a.id and s.tenant_id = p_tenant_id
             and s.is_active = true and s.is_addon = true
         )
       ) then
      raise exception 'addon_invalid' using errcode = 'check_violation';
    end if;
    select coalesce(sum(duration_minutes), 0)::int,
           coalesce(sum(coalesce(deposit_amount, 0)), 0)
      into v_addon_minutes, v_addon_deposit
    from services where id = any (p_addon_ids);
  end if;
  v_duration := v_duration + v_addon_minutes;
  v_deposit  := v_deposit + v_addon_deposit;

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

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours' else null end;

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
      -- 確保此 staff 能做所有 addon
      and not exists (
        select 1 from unnest(p_addon_ids) as a(id)
        where not exists (
          select 1 from staff_services ss2
          where ss2.staff_id = s.id and ss2.service_id = a.id
        )
      )
    order by (
      select count(*) from bookings b
      where b.staff_id = s.id and b.status <> 'cancelled'
        and (b.start_at at time zone v_tz)::date = v_local_date
    ) asc, random()
  loop
    begin
      insert into bookings (tenant_id, staff_id, service_id, member_id,
                            start_at, duration_minutes, status, note,
                            deposit_amount, deposit_status, hold_expires_at,
                            addon_ids)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold,
              p_addon_ids)
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
  uuid, uuid, timestamptz, text, text, text, text, uuid[]) to anon;

-- =============================================================
-- Reports — 一支 RPC 一次拿完報表頁要的數字
-- =============================================================
-- 預設範圍: 過去 30 天 (店家當地時區)
-- 回傳:
--   revenue:     完成預約的 actual_amount 加總 (null → 用 service.price + addons.price)
--   bookings:    各狀態筆數
--   staff:       每個員工的完成數 + 營收
--   services:    每個服務的完成數 + 營收
--   new_vs_returning: 期間內首次預約的客人數 vs 回訪
-- =============================================================
create or replace function public.tenant_report(
  p_tenant_id uuid,
  p_days      int default 30
) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text;
  v_since timestamptz;
  v_result json;
begin
  select timezone into v_tz from tenants where id = p_tenant_id;
  v_since := (now() at time zone v_tz)::date - (p_days - 1);
  v_since := v_since at time zone v_tz;

  with done as (
    -- 範圍內完成的預約
    select b.*,
           coalesce(b.actual_amount,
                    sv.price + coalesce((
                      select sum(adn.price) from services adn
                      where adn.id = any (b.addon_ids)
                    ), 0)
           ) as effective_amount
    from bookings b
    join services sv on sv.id = b.service_id
    where b.tenant_id = p_tenant_id
      and b.start_at >= v_since
      and b.status = 'completed'
  ),
  all_bookings as (
    select * from bookings
    where tenant_id = p_tenant_id and start_at >= v_since
  ),
  per_staff as (
    select s.id, s.name,
           count(d.id) as completed,
           coalesce(sum(d.effective_amount), 0) as revenue
    from staff s
    left join done d on d.staff_id = s.id
    where s.tenant_id = p_tenant_id
    group by s.id, s.name
    order by revenue desc
  ),
  per_service as (
    select sv.id, sv.name,
           count(d.id) as completed,
           coalesce(sum(d.effective_amount), 0) as revenue
    from services sv
    left join done d on d.service_id = sv.id
    where sv.tenant_id = p_tenant_id and sv.is_addon = false
    group by sv.id, sv.name
    order by revenue desc
  ),
  member_visits as (
    select m.id,
           count(distinct b.id) filter (where b.start_at >= v_since) as visits_in_range,
           (select count(*) from bookings b2
              where b2.member_id = m.id and b2.start_at < v_since
                and b2.status <> 'cancelled'
           ) as visits_before
    from members m
    where m.tenant_id = p_tenant_id
  )
  select json_build_object(
    'range_days', p_days,
    'since', v_since,
    'revenue', (select coalesce(sum(effective_amount), 0) from done),
    'bookings_total', (select count(*) from all_bookings),
    'bookings_by_status', (
      select json_object_agg(status, n) from (
        select status, count(*) as n from all_bookings group by status
      ) t
    ),
    'staff', (select coalesce(json_agg(row_to_json(p)), '[]'::json) from per_staff p),
    'services', (select coalesce(json_agg(row_to_json(p)), '[]'::json) from per_service p),
    'new_customers', (
      select count(*) from member_visits
      where visits_in_range > 0 and visits_before = 0
    ),
    'returning_customers', (
      select count(*) from member_visits
      where visits_in_range > 0 and visits_before > 0
    )
  ) into v_result;
  return v_result;
end $$;

grant execute on function public.tenant_report(uuid, int) to authenticated;

-- =============================================================
-- get_available_slots — 也收 p_addon_ids 讓 UI 能算上加購時長
-- =============================================================
-- 簽名變動: 新增第 5 參數 p_addon_ids uuid[]
-- 保留舊簽名(無此參數)以相容
-- =============================================================
create or replace function public.get_available_slots(
  p_staff_id     uuid,
  p_service_id   uuid,
  p_date         date,
  p_slot_minutes int default 15,
  p_addon_ids    uuid[] default '{}'
) returns setof timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz       text;
  v_dur      interval;
  v_dow      int := extract(dow from p_date)::int;
  v_free     tstzmultirange;
  v_avail    tstzmultirange;
  v_blocks   tstzmultirange;
  v_booked   tstzmultirange;
  v_sub      tstzrange;
  v_cursor   timestamptz;
  v_extra    int := 0;
begin
  select t.timezone into v_tz
  from staff s join tenants t on t.id = s.tenant_id where s.id = p_staff_id;
  if v_tz is null then return; end if;

  select (duration_minutes * interval '1 minute') into v_dur
  from services where id = p_service_id;
  if v_dur is null then return; end if;

  -- 加總 addon 時長
  if array_length(p_addon_ids, 1) > 0 then
    select coalesce(sum(duration_minutes), 0)::int into v_extra
    from services where id = any (p_addon_ids) and is_addon = true and is_active = true;
    v_dur := v_dur + (v_extra * interval '1 minute');
  end if;

  select coalesce(range_agg(tstzrange(
           ((p_date + r.start_time) at time zone v_tz),
           ((p_date + r.end_time)   at time zone v_tz))), '{}')
    into v_avail
  from staff_availability_rules r
  where r.staff_id = p_staff_id and r.weekday = v_dow;

  select v_avail + coalesce(range_agg(tstzrange(
           ((p_date + coalesce(e.start_time, time '00:00')) at time zone v_tz),
           ((p_date + coalesce(e.end_time,   time '23:59')) at time zone v_tz))), '{}')
    into v_avail
  from staff_availability_exceptions e
  where e.staff_id = p_staff_id and e.date = p_date and e.kind = 'extra';

  select coalesce(range_agg(tstzrange(
           ((p_date + coalesce(e.start_time, time '00:00')) at time zone v_tz),
           ((p_date + coalesce(e.end_time,   time '23:59')) at time zone v_tz))), '{}')
    into v_blocks
  from staff_availability_exceptions e
  where e.staff_id = p_staff_id and e.date = p_date and e.kind = 'block';

  select coalesce(range_agg(b.time_range), '{}') into v_booked
  from bookings b
  where b.staff_id = p_staff_id and b.status <> 'cancelled'
    and b.start_at >= ((p_date) at time zone v_tz)
    and b.start_at <  ((p_date + 1) at time zone v_tz);

  v_free := v_avail - v_blocks - v_booked;

  for v_sub in select unnest(v_free) loop
    v_cursor := lower(v_sub);
    while v_cursor + v_dur <= upper(v_sub) loop
      return next v_cursor;
      v_cursor := v_cursor + (p_slot_minutes * interval '1 minute');
    end loop;
  end loop;
end $$;

grant execute on function public.get_available_slots(uuid, uuid, date, int, uuid[]) to anon;
