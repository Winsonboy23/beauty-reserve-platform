-- =============================================================
-- 0002 — 訂金 & 不指定設計師預約
-- =============================================================
-- 接續 0001_booking_core.sql。兩個重點：
--   A. 訂金：未付款的預約只「暫時保留」slot，逾時自動釋放，
--      否則沒付錢的人會永久卡位。
--   B. 不指定設計師：在「建立當下」指派到真實設計師，不存 null staff_id
--      ——因為 exclusion constraint 對 null 無效，存 null 等於失去防重疊。
-- =============================================================

create type deposit_status as enum ('none', 'pending', 'paid', 'refunded', 'forfeited');

-- 服務可設定需收的訂金(null 或 0 = 免訂金)
alter table services
  add column deposit_amount numeric(10,2)
    check (deposit_amount is null or deposit_amount >= 0);

-- 預約加上訂金 / 金流欄位
alter table bookings
  add column deposit_amount   numeric(10,2) not null default 0,
  add column deposit_status   deposit_status not null default 'none',
  add column payment_provider text,            -- 'ecpay' | 'newebpay'
  add column payment_ref      text,            -- 金流交易編號
  add column paid_at          timestamptz,
  add column hold_expires_at  timestamptz;     -- 未付訂金的保留到期時間

-- 加速 cleanup 掃描
create index on bookings(hold_expires_at)
  where deposit_status = 'pending' and status = 'pending';

-- =============================================================
-- A. 重寫 create_booking：建立時帶入訂金狀態與保留期限
--    (簽名不變，沿用 0001 的 anon grant)
-- =============================================================
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

  -- 需訂金 → 先暫時保留(v1 人工轉帳, 24 小時),確認入帳後才轉 confirmed
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

-- =============================================================
-- 金流 webhook 回呼：標記訂金已付 → 確認預約
-- 由後端 webhook handler 以 service_role 呼叫(繞過 RLS),不開放 anon。
-- =============================================================
create or replace function public.mark_deposit_paid(
  p_booking_id   uuid,
  p_provider     text,
  p_provider_ref text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bookings
  set deposit_status   = 'paid',
      status           = case when status = 'pending' then 'confirmed' else status end,
      payment_provider = p_provider,
      payment_ref      = p_provider_ref,
      paid_at          = now(),
      hold_expires_at  = null
  where id = p_booking_id and deposit_status = 'pending';
end $$;

-- =============================================================
-- 釋放逾時未付訂金的保留 slot。用 pg_cron 每數分鐘跑一次。
--   create extension if not exists pg_cron;
--   select cron.schedule('release-holds','*/5 * * * *',
--                        'select public.cleanup_expired_holds()');
-- =============================================================
create or replace function public.cleanup_expired_holds()
returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  with upd as (
    update bookings
    set status = 'cancelled'
    where status = 'pending'
      and deposit_status = 'pending'
      and hold_expires_at is not null
      and hold_expires_at < now()
    returning 1
  )
  select count(*) into v_n from upd;
  return v_n;
end $$;

-- =============================================================
-- B. 不指定設計師預約：建立當下指派到真實的可用設計師
--    策略：可做此服務 + 該時段有空者中,挑當日預約數最少的(平均分配),
--    依序嘗試;若某位剛好被搶(exclusion_violation)就換下一位。
-- =============================================================
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

  -- 依「當日預約數」由少到多嘗試指派(同數量隨機)
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

      staff_id := v_cand;   -- 指派成功
      return;
    exception when exclusion_violation then
      continue;             -- 這位剛被搶,換下一位
    end;
  end loop;

  -- 沒有任何可用設計師
  raise exception 'no_staff_available' using errcode = 'check_violation';
end $$;

grant execute on function public.create_booking_any(
  uuid, uuid, timestamptz, text, text, text, text) to anon;
