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
