-- =============================================================
-- 0016 — 優惠券 / 折扣碼
-- =============================================================
-- 兩張表 + 驗證 RPC + create_booking 整合:
--   coupons        — 券定義 (券名 / 碼 / 類型 / 折扣 / 限制 / 期限)
--   coupon_uses    — 券使用紀錄 (booking + member + amount_off)
--   validate_coupon — 驗證 + 計算折扣 (給 /book 即時 preview 用)
--   create_booking 新增 p_coupon_code 參數,在內部 validate + 套用 + 寫 coupon_uses
--
-- 設計考量:
--   1. 一筆 booking 只能用一張券 (unique on booking_id in coupon_uses)
--   2. 取消 booking → cascade 刪 coupon_uses → max_uses 計數會自動回復
--   3. validate_coupon 對 anon callable (客人預覽); 真正套用在 create_booking 內
--      避免「validate ok 但 race condition 後超量」
-- =============================================================

create table public.coupons (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  code            text not null,    -- 上限 32 字, 統一存大寫
  name            text not null,    -- 顯示名稱 (給後台看)
  discount_type   text not null check (discount_type in ('percent', 'fixed')),
  discount_value  numeric(10,2) not null check (discount_value > 0),
  min_amount      numeric(10,2),    -- 最低消費門檻; null = 無限制
  max_uses        int,              -- 總用量上限; null = 無限
  max_uses_per_member int default 1,-- 每人用量上限; null = 無限
  valid_from      timestamptz,
  valid_until     timestamptz,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (tenant_id, code)
);

create index on public.coupons(tenant_id, is_active) where is_active;

alter table public.coupons enable row level security;

create policy tenant_isolation on public.coupons
  for all to authenticated
  using (tenant_id in (select public.current_tenant_ids()))
  with check (tenant_id in (select public.current_tenant_ids()));

grant select, insert, update, delete on public.coupons to authenticated;
grant select, insert, update, delete on public.coupons to service_role;
-- anon 不直接讀 coupons (避免列舉所有券); 只透過 validate_coupon RPC 驗證

-- =============================================================
-- coupon_uses
-- =============================================================
create table public.coupon_uses (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  coupon_id   uuid not null references public.coupons(id) on delete cascade,
  booking_id  uuid not null references public.bookings(id) on delete cascade,
  member_id   uuid references public.members(id) on delete set null,
  amount_off  numeric(10,2) not null,
  used_at     timestamptz not null default now(),
  unique (booking_id)  -- 一 booking 一券
);

create index on public.coupon_uses(coupon_id);
create index on public.coupon_uses(member_id);
create index on public.coupon_uses(tenant_id, used_at desc);

alter table public.coupon_uses enable row level security;

create policy tenant_isolation on public.coupon_uses
  for all to authenticated
  using (tenant_id in (select public.current_tenant_ids()))
  with check (tenant_id in (select public.current_tenant_ids()));

grant select, insert, update, delete on public.coupon_uses to authenticated;
grant select, insert, update, delete on public.coupon_uses to service_role;

-- =============================================================
-- bookings 加欄位: coupon_id (denormalized for easy query)
-- 注意: 真實 amount_off 看 coupon_uses; bookings 這兩欄只是方便 JOIN
-- =============================================================
alter table public.bookings add column coupon_id uuid references public.coupons(id) on delete set null;
alter table public.bookings add column discount_amount numeric(10,2);

-- =============================================================
-- validate_coupon — 驗證 + 計算折扣 (給 /book 預覽)
-- 不寫入 coupon_uses, 只回傳結果
-- =============================================================
create or replace function public.validate_coupon(
  p_tenant_id     uuid,
  p_code          text,
  p_amount        numeric,             -- 預約原價 (含 addon)
  p_member_phone  text default null    -- 用於 per-member limit check
) returns table (
  valid         boolean,
  reason        text,
  coupon_id     uuid,
  coupon_name   text,
  amount_off    numeric,
  final_amount  numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_coupon record;
  v_member_uses int := 0;
  v_total_uses int := 0;
  v_off numeric;
  v_code text := upper(trim(p_code));
begin
  if v_code = '' then
    return query select false, 'empty_code'::text, null::uuid, null::text, 0::numeric, p_amount;
    return;
  end if;

  select * into v_coupon
  from coupons
  where tenant_id = p_tenant_id and code = v_code
    and is_active = true
    and (valid_from is null or valid_from <= now())
    and (valid_until is null or valid_until >= now())
  limit 1;

  if v_coupon is null then
    return query select false, 'not_found'::text, null::uuid, null::text, 0::numeric, p_amount;
    return;
  end if;

  if v_coupon.min_amount is not null and p_amount < v_coupon.min_amount then
    return query select false, 'min_amount_not_met'::text, v_coupon.id, v_coupon.name, 0::numeric, p_amount;
    return;
  end if;

  if v_coupon.max_uses is not null then
    select count(*) into v_total_uses from coupon_uses where coupon_id = v_coupon.id;
    if v_total_uses >= v_coupon.max_uses then
      return query select false, 'max_uses_reached'::text, v_coupon.id, v_coupon.name, 0::numeric, p_amount;
      return;
    end if;
  end if;

  if v_coupon.max_uses_per_member is not null and p_member_phone is not null then
    select count(*) into v_member_uses
    from coupon_uses cu
    join members m on m.id = cu.member_id
    where cu.coupon_id = v_coupon.id
      and m.phone = p_member_phone and m.tenant_id = p_tenant_id;
    if v_member_uses >= v_coupon.max_uses_per_member then
      return query select false, 'member_limit_reached'::text, v_coupon.id, v_coupon.name, 0::numeric, p_amount;
      return;
    end if;
  end if;

  if v_coupon.discount_type = 'percent' then
    v_off := round(p_amount * (v_coupon.discount_value / 100), 0);
  else
    v_off := v_coupon.discount_value;
  end if;
  v_off := least(v_off, p_amount);

  return query select true, 'ok'::text, v_coupon.id, v_coupon.name, v_off, (p_amount - v_off);
end $$;

grant execute on function public.validate_coupon(uuid, text, numeric, text) to anon, authenticated;

-- =============================================================
-- create_booking — 新增 p_coupon_code 參數,在內部 validate + 套用
-- =============================================================
drop function if exists public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[]);

create or replace function public.create_booking(
  p_tenant_id      uuid,
  p_staff_id       uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null,
  p_addon_ids      uuid[] default '{}',
  p_coupon_code    text default null
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
  v_caller uuid := auth.uid();
  v_service_price numeric(10,2) := 0;
  v_addon_price numeric(10,2) := 0;
  v_subtotal numeric(10,2);
  v_coupon record;
  v_off numeric(10,2) := 0;
  v_total_uses int;
  v_member_uses int;
begin
  -- 1) 方案限制
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  -- 2) 主服務
  select duration_minutes, coalesce(deposit_amount, 0), price
    into v_duration, v_deposit, v_service_price
  from services
  where id = p_service_id and tenant_id = p_tenant_id
    and is_active = true and is_addon = false;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  -- 3) staff
  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  -- 4) addon
  if array_length(p_addon_ids, 1) > 0 then
    if exists (
         select 1 from unnest(p_addon_ids) as a(id)
         where not exists (
           select 1 from services s
           join staff_services ss on ss.service_id = s.id
           where s.id = a.id and s.tenant_id = p_tenant_id
             and s.is_active = true and s.is_addon = true
             and ss.staff_id = p_staff_id
         )
       ) then
      raise exception 'addon_invalid' using errcode = 'check_violation';
    end if;
    select coalesce(sum(duration_minutes), 0)::int,
           coalesce(sum(coalesce(deposit_amount, 0)), 0),
           coalesce(sum(price), 0)
      into v_addon_minutes, v_addon_deposit, v_addon_price
    from services where id = any (p_addon_ids);
  end if;
  v_duration := v_duration + v_addon_minutes;
  v_deposit  := v_deposit + v_addon_deposit;
  v_subtotal := v_service_price + v_addon_price;

  -- 5) slot
  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  -- 6) free 不收訂金
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

  -- 8) 優惠券驗證 (與 validate_coupon 邏輯一致, 但在 transaction 內以避免 race)
  if p_coupon_code is not null and length(trim(p_coupon_code)) > 0 then
    select * into v_coupon
    from coupons
    where tenant_id = p_tenant_id and code = upper(trim(p_coupon_code))
      and is_active = true
      and (valid_from is null or valid_from <= now())
      and (valid_until is null or valid_until >= now())
    limit 1;

    if v_coupon is null then
      raise exception 'coupon_invalid' using errcode = 'check_violation';
    end if;
    if v_coupon.min_amount is not null and v_subtotal < v_coupon.min_amount then
      raise exception 'coupon_min_amount' using errcode = 'check_violation';
    end if;
    if v_coupon.max_uses is not null then
      select count(*) into v_total_uses from coupon_uses where coupon_id = v_coupon.id;
      if v_total_uses >= v_coupon.max_uses then
        raise exception 'coupon_max_uses' using errcode = 'check_violation';
      end if;
    end if;
    if v_coupon.max_uses_per_member is not null then
      select count(*) into v_member_uses
      from coupon_uses cu
      join members m on m.id = cu.member_id
      where cu.coupon_id = v_coupon.id
        and m.phone = p_customer_phone and m.tenant_id = p_tenant_id;
      if v_member_uses >= v_coupon.max_uses_per_member then
        raise exception 'coupon_member_limit' using errcode = 'check_violation';
      end if;
    end if;
    if v_coupon.discount_type = 'percent' then
      v_off := round(v_subtotal * (v_coupon.discount_value / 100), 0);
    else
      v_off := v_coupon.discount_value;
    end if;
    v_off := least(v_off, v_subtotal);
  end if;

  -- 9) deposit / hold
  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours' else null end;

  -- 10) upsert member
  insert into members (tenant_id, name, phone, email, user_id)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email, v_caller)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email),
                user_id = coalesce(members.user_id, excluded.user_id)
  returning id into v_member_id;

  -- 11) insert booking
  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at,
                          addon_ids, coupon_id, discount_amount)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold,
            p_addon_ids,
            case when v_coupon.id is not null then v_coupon.id else null end,
            case when v_off > 0 then v_off else null end)
    returning id, bookings.manage_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  -- 12) 記錄優惠券使用
  if v_coupon.id is not null then
    insert into coupon_uses (tenant_id, coupon_id, booking_id, member_id, amount_off)
    values (p_tenant_id, v_coupon.id, v_id, v_member_id, v_off);
  end if;

  booking_id := v_id;
  manage_token := v_token;
  return next;
end $$;

grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[], text) to anon, authenticated;

-- =============================================================
-- create_booking_any — 同樣加 p_coupon_code
-- =============================================================
drop function if exists public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text, uuid[]);

create or replace function public.create_booking_any(
  p_tenant_id      uuid,
  p_service_id     uuid,
  p_start_at       timestamptz,
  p_customer_name  text,
  p_customer_phone text,
  p_customer_email text default null,
  p_note           text default null,
  p_addon_ids      uuid[] default '{}',
  p_coupon_code    text default null,
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
  v_caller uuid := auth.uid();
  v_service_price numeric(10,2) := 0;
  v_addon_price numeric(10,2) := 0;
  v_subtotal numeric(10,2);
  v_coupon record;
  v_off numeric(10,2) := 0;
  v_total_uses int;
  v_member_uses int;
begin
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  select duration_minutes, coalesce(deposit_amount, 0), price
    into v_duration, v_deposit, v_service_price
  from services
  where id = p_service_id and tenant_id = p_tenant_id
    and is_active = true and is_addon = false;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

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
           coalesce(sum(coalesce(deposit_amount, 0)), 0),
           coalesce(sum(price), 0)
      into v_addon_minutes, v_addon_deposit, v_addon_price
    from services where id = any (p_addon_ids);
  end if;
  v_duration := v_duration + v_addon_minutes;
  v_deposit  := v_deposit + v_addon_deposit;
  v_subtotal := v_service_price + v_addon_price;

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

  -- 優惠券
  if p_coupon_code is not null and length(trim(p_coupon_code)) > 0 then
    select * into v_coupon
    from coupons
    where tenant_id = p_tenant_id and code = upper(trim(p_coupon_code))
      and is_active = true
      and (valid_from is null or valid_from <= now())
      and (valid_until is null or valid_until >= now())
    limit 1;
    if v_coupon is null then
      raise exception 'coupon_invalid' using errcode = 'check_violation';
    end if;
    if v_coupon.min_amount is not null and v_subtotal < v_coupon.min_amount then
      raise exception 'coupon_min_amount' using errcode = 'check_violation';
    end if;
    if v_coupon.max_uses is not null then
      select count(*) into v_total_uses from coupon_uses where coupon_id = v_coupon.id;
      if v_total_uses >= v_coupon.max_uses then
        raise exception 'coupon_max_uses' using errcode = 'check_violation';
      end if;
    end if;
    if v_coupon.max_uses_per_member is not null then
      select count(*) into v_member_uses
      from coupon_uses cu
      join members m on m.id = cu.member_id
      where cu.coupon_id = v_coupon.id
        and m.phone = p_customer_phone and m.tenant_id = p_tenant_id;
      if v_member_uses >= v_coupon.max_uses_per_member then
        raise exception 'coupon_member_limit' using errcode = 'check_violation';
      end if;
    end if;
    if v_coupon.discount_type = 'percent' then
      v_off := round(v_subtotal * (v_coupon.discount_value / 100), 0);
    else
      v_off := v_coupon.discount_value;
    end if;
    v_off := least(v_off, v_subtotal);
  end if;

  v_dep_status := case when v_deposit > 0 then 'pending'::deposit_status else 'none'::deposit_status end;
  v_hold       := case when v_deposit > 0 then now() + interval '24 hours' else null end;

  insert into members (tenant_id, name, phone, email, user_id)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email, v_caller)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email),
                user_id = coalesce(members.user_id, excluded.user_id)
  returning id into v_member_id;

  for v_cand in
    select s.id from staff s
    join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
    where s.tenant_id = p_tenant_id and s.is_active = true
      and public.is_slot_available(s.id, p_start_at, v_duration)
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
                            addon_ids, coupon_id, discount_amount)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold,
              p_addon_ids,
              case when v_coupon.id is not null then v_coupon.id else null end,
              case when v_off > 0 then v_off else null end)
      returning id, bookings.manage_token into booking_id, manage_token;

      staff_id := v_cand;
      if v_coupon.id is not null then
        insert into coupon_uses (tenant_id, coupon_id, booking_id, member_id, amount_off)
        values (p_tenant_id, v_coupon.id, booking_id, v_member_id, v_off);
      end if;
      return;
    exception when exclusion_violation then
      continue;
    end;
  end loop;

  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

grant execute on function public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text, uuid[], text) to anon, authenticated;
