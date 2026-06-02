-- =============================================================
-- 0018 — 點數兌換 (redeem at booking)
-- =============================================================
-- /book 時客人 (需登入) 可指定 p_points_to_redeem,RPC 內部:
--   1. 驗證該 member.user_id = auth.uid() (不可幫別人花)
--   2. 驗 balance >= 要扣的點數
--   3. 計算折抵金額 = points * redeem_value
--   4. 折抵不能超過「扣完優惠券後的金額」
--   5. 在同 transaction 扣 member.points_balance + insert 負的 loyalty_transactions
--
-- 折扣計算順序:
--   subtotal      = service_price + sum(addon prices)
--   after_coupon  = subtotal - coupon_off
--   after_points  = after_coupon - points_discount
--   final         = max(0, after_points)
--
-- bookings 紀錄 points_used (點數) + points_discount ($) 方便報表 / 客人看歷史
-- =============================================================

alter table public.bookings
  add column points_used     int not null default 0,
  add column points_discount numeric(10,2) not null default 0;

-- =============================================================
-- create_booking — 新增 p_points_to_redeem
-- =============================================================
drop function if exists public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[], text);

create or replace function public.create_booking(
  p_tenant_id       uuid,
  p_staff_id        uuid,
  p_service_id      uuid,
  p_start_at        timestamptz,
  p_customer_name   text,
  p_customer_phone  text,
  p_customer_email  text default null,
  p_note            text default null,
  p_addon_ids       uuid[] default '{}',
  p_coupon_code     text default null,
  p_points_to_redeem int default 0
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
  v_member_user_id uuid;
  v_member_balance int;
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
  v_redeem_value numeric(10,2);
  v_points_to_use int := 0;
  v_points_discount numeric(10,2) := 0;
  v_after_coupon numeric(10,2);
begin
  -- 方案
  select bookings_per_month, bookings_this_month
    into v_book_limit, v_used
  from public.plan_limits((select plan from public.tenant_usage(p_tenant_id))),
       public.tenant_usage(p_tenant_id);
  if v_book_limit > 0 and v_used >= v_book_limit then
    raise exception 'plan_limit_exceeded' using errcode = 'check_violation';
  end if;

  -- 主服務
  select duration_minutes, coalesce(deposit_amount, 0), price
    into v_duration, v_deposit, v_service_price
  from services
  where id = p_service_id and tenant_id = p_tenant_id
    and is_active = true and is_addon = false;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  -- staff
  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  -- addon
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

  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  if v_deposit > 0 and not (select can_deposit from public.plan_limits(
       (select plan from public.tenant_usage(p_tenant_id)))) then
    v_deposit := 0;
  end if;

  -- 黑名單
  select is_blacklisted, user_id, points_balance
    into v_blacklisted, v_member_user_id, v_member_balance
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

  v_after_coupon := v_subtotal - v_off;

  -- 點數兌換
  if p_points_to_redeem > 0 then
    if v_caller is null then
      raise exception 'points_login_required' using errcode = 'insufficient_privilege';
    end if;
    -- 一定要有對應的 member,且 user_id = 呼叫者
    if v_member_user_id is null then
      raise exception 'points_member_not_linked' using errcode = 'check_violation';
    end if;
    if v_member_user_id <> v_caller then
      raise exception 'points_not_owner' using errcode = 'insufficient_privilege';
    end if;
    -- 餘額
    if coalesce(v_member_balance, 0) < p_points_to_redeem then
      raise exception 'points_insufficient' using errcode = 'check_violation';
    end if;
    select points_redeem_value into v_redeem_value from tenants where id = p_tenant_id;
    if coalesce(v_redeem_value, 0) <= 0 then
      raise exception 'points_redeem_disabled' using errcode = 'check_violation';
    end if;
    -- cap: 不能折超過 after_coupon
    v_points_to_use := least(p_points_to_redeem, floor(v_after_coupon / v_redeem_value)::int);
    v_points_to_use := greatest(0, v_points_to_use);
    v_points_discount := v_points_to_use * v_redeem_value;
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

  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note,
                          deposit_amount, deposit_status, hold_expires_at,
                          addon_ids,
                          coupon_id, discount_amount,
                          points_used, points_discount)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note,
            v_deposit, v_dep_status, v_hold,
            p_addon_ids,
            case when v_coupon.id is not null then v_coupon.id else null end,
            case when v_off > 0 then v_off else null end,
            v_points_to_use, v_points_discount)
    returning id, bookings.manage_token into v_id, v_token;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  if v_coupon.id is not null then
    insert into coupon_uses (tenant_id, coupon_id, booking_id, member_id, amount_off)
    values (p_tenant_id, v_coupon.id, v_id, v_member_id, v_off);
  end if;

  -- 扣點 + 寫 loyalty_transactions
  if v_points_to_use > 0 then
    update members
      set points_balance = points_balance - v_points_to_use
      where id = v_member_id
      returning points_balance into v_member_balance;
    insert into loyalty_transactions
      (tenant_id, member_id, points, balance_after, source, booking_id, note)
    values
      (p_tenant_id, v_member_id, -v_points_to_use, v_member_balance,
       'redeemed', v_id,
       format('預約 %s 折抵 $%s', upper(substr(v_id::text, 1, 6)), v_points_discount::text));
  end if;

  booking_id := v_id;
  manage_token := v_token;
  return next;
end $$;

grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[], text, int) to anon, authenticated;

-- =============================================================
-- create_booking_any — 同上,加 p_points_to_redeem
-- =============================================================
drop function if exists public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text, uuid[], text);

create or replace function public.create_booking_any(
  p_tenant_id       uuid,
  p_service_id      uuid,
  p_start_at        timestamptz,
  p_customer_name   text,
  p_customer_phone  text,
  p_customer_email  text default null,
  p_note            text default null,
  p_addon_ids       uuid[] default '{}',
  p_coupon_code     text default null,
  p_points_to_redeem int default 0,
  out booking_id    uuid,
  out staff_id      uuid,
  out manage_token  text
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
  v_member_user_id uuid;
  v_member_balance int;
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
  v_redeem_value numeric(10,2);
  v_points_to_use int := 0;
  v_points_discount numeric(10,2) := 0;
  v_after_coupon numeric(10,2);
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

  select is_blacklisted, user_id, points_balance
    into v_blacklisted, v_member_user_id, v_member_balance
  from members where tenant_id = p_tenant_id and phone = p_customer_phone;
  if coalesce(v_blacklisted, false) then
    raise exception 'member_blacklisted' using errcode = 'check_violation';
  end if;

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
  v_after_coupon := v_subtotal - v_off;

  if p_points_to_redeem > 0 then
    if v_caller is null then
      raise exception 'points_login_required' using errcode = 'insufficient_privilege';
    end if;
    if v_member_user_id is null then
      raise exception 'points_member_not_linked' using errcode = 'check_violation';
    end if;
    if v_member_user_id <> v_caller then
      raise exception 'points_not_owner' using errcode = 'insufficient_privilege';
    end if;
    if coalesce(v_member_balance, 0) < p_points_to_redeem then
      raise exception 'points_insufficient' using errcode = 'check_violation';
    end if;
    select points_redeem_value into v_redeem_value from tenants where id = p_tenant_id;
    if coalesce(v_redeem_value, 0) <= 0 then
      raise exception 'points_redeem_disabled' using errcode = 'check_violation';
    end if;
    v_points_to_use := least(p_points_to_redeem, floor(v_after_coupon / v_redeem_value)::int);
    v_points_to_use := greatest(0, v_points_to_use);
    v_points_discount := v_points_to_use * v_redeem_value;
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
                            addon_ids, coupon_id, discount_amount,
                            points_used, points_discount)
      values (p_tenant_id, v_cand, p_service_id, v_member_id,
              p_start_at, v_duration, 'pending', p_note,
              v_deposit, v_dep_status, v_hold,
              p_addon_ids,
              case when v_coupon.id is not null then v_coupon.id else null end,
              case when v_off > 0 then v_off else null end,
              v_points_to_use, v_points_discount)
      returning id, bookings.manage_token into booking_id, manage_token;
      staff_id := v_cand;
      if v_coupon.id is not null then
        insert into coupon_uses (tenant_id, coupon_id, booking_id, member_id, amount_off)
        values (p_tenant_id, v_coupon.id, booking_id, v_member_id, v_off);
      end if;
      if v_points_to_use > 0 then
        update members
          set points_balance = points_balance - v_points_to_use
          where id = v_member_id
          returning points_balance into v_member_balance;
        insert into loyalty_transactions
          (tenant_id, member_id, points, balance_after, source, booking_id, note)
        values
          (p_tenant_id, v_member_id, -v_points_to_use, v_member_balance,
           'redeemed', booking_id,
           format('預約 %s 折抵 $%s', upper(substr(booking_id::text, 1, 6)), v_points_discount::text));
      end if;
      return;
    exception when exclusion_violation then
      continue;
    end;
  end loop;

  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

grant execute on function public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text, uuid[], text, int) to anon, authenticated;
