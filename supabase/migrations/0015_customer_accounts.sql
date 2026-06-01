-- =============================================================
-- 0015 — 客人端會員系統 (customer accounts)
-- =============================================================
-- 客人能 sign up 到 Supabase Auth, 綁定既有 members 紀錄,看自己的預約。
-- 業主跟客人共用 auth.users; 區分:
--   - 在 tenant_members  → 業主 (後台)
--   - 在 members.user_id → 客人
-- 同一人可能既是 A 店業主也是 B 店客人, 沒衝突。
-- =============================================================

alter table public.members
  add column user_id uuid references auth.users(id) on delete set null;

create unique index members_tenant_user_uniq
  on public.members(tenant_id, user_id) where user_id is not null;
-- 一個 user 在同一店只能對應一個 member; 同一 user 可在多店有 member

-- ============================================
-- RLS — 客人可讀自己的 member / bookings
-- 既有 tenant_isolation 政策不動 (業主走那條)
-- ============================================
create policy member_self_read on public.members
  for select to authenticated
  using (user_id = auth.uid());

create policy booking_self_read on public.bookings
  for select to authenticated
  using (member_id in (select id from members where user_id = auth.uid()));

-- ============================================
-- RPC: 客人登入後綁定 member by phone
--   - 已有 member with this phone → claim (若 user_id null 或已是自己)
--   - 沒有 → 建新 member (用 auth.email)
--   - 已被別人 claim → 拋 phone_already_claimed
-- ============================================
create or replace function public.customer_link_member(
  p_tenant_id uuid,
  p_phone     text
) returns table (member_id uuid, was_new boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_member_id uuid;
  v_existing_user_id uuid;
  v_email text;
  v_name text;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_phone is null or length(trim(p_phone)) < 6 then
    raise exception 'invalid_phone' using errcode = 'check_violation';
  end if;

  select u.email, coalesce(u.raw_user_meta_data->>'name', split_part(u.email, '@', 1))
    into v_email, v_name
  from auth.users u where u.id = v_uid;

  select id, user_id into v_member_id, v_existing_user_id
  from members where tenant_id = p_tenant_id and phone = p_phone;

  if v_member_id is not null then
    if v_existing_user_id is not null and v_existing_user_id <> v_uid then
      raise exception 'phone_already_claimed' using errcode = 'unique_violation';
    end if;
    update members
      set user_id = v_uid,
          email   = coalesce(email, v_email)
      where id = v_member_id;
    return query select v_member_id, false;
  else
    insert into members (tenant_id, name, phone, email, user_id)
    values (p_tenant_id, v_name, p_phone, v_email, v_uid)
    returning id into v_member_id;
    return query select v_member_id, true;
  end if;
end $$;

grant execute on function public.customer_link_member(uuid, text) to authenticated;

-- ============================================
-- RPC: 客人自助改期 (JWT 認證, 不用 token)
-- ============================================
create or replace function public.customer_reschedule(
  p_booking_id   uuid,
  p_new_start_at timestamptz
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_staff uuid;
  v_dur int;
  v_status booking_status;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select b.staff_id, b.duration_minutes, b.status
    into v_staff, v_dur, v_status
  from bookings b
  join members m on m.id = b.member_id
  where b.id = p_booking_id and m.user_id = v_uid;

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

grant execute on function public.customer_reschedule(uuid, timestamptz) to authenticated;

-- ============================================
-- RPC: 客人自助取消
-- ============================================
create or replace function public.customer_cancel(p_booking_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_status booking_status;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select b.status into v_status
  from bookings b
  join members m on m.id = b.member_id
  where b.id = p_booking_id and m.user_id = v_uid;

  if v_status is null then
    raise exception 'booking_not_found' using errcode = 'no_data_found';
  end if;
  if v_status in ('cancelled', 'completed', 'no_show') then
    raise exception 'booking_not_modifiable' using errcode = 'check_violation';
  end if;

  update bookings set status = 'cancelled' where id = p_booking_id;
end $$;

grant execute on function public.customer_cancel(uuid) to authenticated;

-- ============================================
-- /book 預約時若客人已登入,自動 claim member
-- → 改寫 create_booking, 加 inner upsert 邏輯帶 user_id
-- ============================================
-- 因為 create_booking 是 SECURITY DEFINER 跑在 postgres 角色,
-- auth.uid() 仍會回到「呼叫者的 user_id」(若有的話)。anon 呼叫時 auth.uid() = null。
-- 所以在 upsert member 時帶上 auth.uid() 即可。
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
  v_caller uuid := auth.uid();
begin
  -- 方案限制
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

  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

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
           coalesce(sum(coalesce(deposit_amount, 0)), 0)
      into v_addon_minutes, v_addon_deposit
    from services where id = any (p_addon_ids);
  end if;
  v_duration := v_duration + v_addon_minutes;
  v_deposit  := v_deposit + v_addon_deposit;

  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

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

  -- upsert member; 若呼叫者已登入且該 member 還沒綁 user_id → 自動綁
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
  uuid, uuid, uuid, timestamptz, text, text, text, text, uuid[]) to anon, authenticated;
