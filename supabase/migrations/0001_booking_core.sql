-- =============================================================
-- 美業 SaaS 預約系統 — 核心 Schema (Supabase / PostgreSQL 15+)
-- =============================================================
-- 設計重點：
--   1. 多租戶：所有業務表都帶 tenant_id，靠 RLS 隔離。
--   2. 預約並發：用 GiST exclusion constraint 在「DB 層」保證同一
--      設計師時段不重疊，application 層不需要也不該自己鎖。
--   3. 時段模型分兩層：規則性(recurring) + 例外(exception)。
--   4. 公開預約(消費者)走 SECURITY DEFINER RPC，不直接開放 bookings
--      表給 anon，避免繞過驗證。
--   5. 時區：時段規則存「店家當地時間」，比對時用 tenants.timezone
--      換算，避免 UTC/本地時間混用造成排班錯位。
-- =============================================================

create extension if not exists btree_gist;   -- exclusion constraint 需要(uuid 等值比較)
create extension if not exists pgcrypto;      -- gen_random_uuid()

-- ---------- 列舉型別 ----------
create type plan_tier          as enum ('free', 'basic', 'pro');
create type subscription_status as enum ('trialing', 'active', 'past_due', 'paused', 'canceled');
create type booking_status     as enum ('pending', 'confirmed', 'completed', 'cancelled', 'no_show');
create type availability_kind  as enum ('block', 'extra');  -- block=當日不可約, extra=當日加開

-- ---------- 共用 updated_at 觸發器 ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- =============================================================
-- 租戶 & 成員(後台使用者)
-- =============================================================
create table tenants (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,                 -- 子網域 shop.<slug>.yoursaas.tw
  timezone    text not null default 'Asia/Taipei',  -- 時段比對基準
  plan        plan_tier not null default 'free',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 後台使用者 ↔ 租戶(老闆/員工帳號)。消費者不在這裡。
create table tenant_members (
  tenant_id   uuid not null references tenants(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'staff',  -- 'owner' | 'manager' | 'staff'
  created_at  timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index on tenant_members(user_id);

-- 訂閱狀態機
create table subscriptions (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null unique references tenants(id) on delete cascade,
  plan         plan_tier not null default 'free',
  status       subscription_status not null default 'trialing',
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  provider     text,                 -- 'ecpay' | 'newebpay' | 'paddle'
  provider_ref text,                 -- 對應金流端的訂閱/會員編號
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create trigger trg_sub_updated before update on subscriptions
  for each row execute function public.set_updated_at();

-- =============================================================
-- 設計師 / 服務
-- =============================================================
create table staff (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  user_id     uuid references auth.users(id),  -- 設計師可登入後台時連結
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on staff(tenant_id) where is_active;
create trigger trg_staff_updated before update on staff
  for each row execute function public.set_updated_at();

create table service_categories (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  name        text not null,
  sort_order  int not null default 0
);
create index on service_categories(tenant_id);

create table services (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  category_id     uuid references service_categories(id) on delete set null,
  name            text not null,
  duration_minutes int not null check (duration_minutes > 0),
  price           numeric(10,2) not null check (price >= 0),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);
create index on services(tenant_id) where is_active;

-- 哪些設計師能做哪些服務(多對多)
create table staff_services (
  tenant_id   uuid not null references tenants(id) on delete cascade,
  staff_id    uuid not null references staff(id) on delete cascade,
  service_id  uuid not null references services(id) on delete cascade,
  primary key (staff_id, service_id)
);
create index on staff_services(tenant_id);

-- =============================================================
-- 會員(消費者)
-- =============================================================
create table members (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  name        text not null,
  phone       text not null,
  email       text,
  note        text,                      -- 膚質/過敏/偏好等
  tags        text[] not null default '{}',
  created_at  timestamptz not null default now(),
  unique (tenant_id, phone)              -- 同店電話為自然鍵
);
create index on members(tenant_id);

-- =============================================================
-- 時段：兩層模型
-- =============================================================
-- (1) 規則性可用時段：每週固定班表。weekday 用 PostgreSQL dow 慣例
--     0=週日, 1=週一, ... 6=週六。時間存當地時間。
create table staff_availability_rules (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  staff_id    uuid not null references staff(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  start_time  time not null,
  end_time    time not null,
  check (end_time > start_time)
);
create index on staff_availability_rules(staff_id, weekday);

-- (2) 例外：針對特定日期。block=請假/特休(該段不可約)，extra=臨時加開。
--     start_time/end_time 皆為 null 代表整天。
create table staff_availability_exceptions (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references tenants(id) on delete cascade,
  staff_id    uuid not null references staff(id) on delete cascade,
  date        date not null,
  kind        availability_kind not null,
  start_time  time,
  end_time    time,
  reason      text,
  check (start_time is null or end_time is null or end_time > start_time)
);
create index on staff_availability_exceptions(staff_id, date);

-- =============================================================
-- 預約(核心)
-- =============================================================
create table bookings (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  staff_id        uuid not null references staff(id),
  service_id      uuid not null references services(id),
  member_id       uuid not null references members(id),
  start_at        timestamptz not null,
  duration_minutes int not null check (duration_minutes > 0),
  -- 由 start_at + duration 自動算出的時間範圍，供 exclusion 用
  -- 注意: 必須用 make_interval(IMMUTABLE), 不能用 duration_minutes * interval '1 minute'(STABLE),
  -- 否則 Postgres 會以 42P17 generation expression is not immutable 拒絕 generated column。
  time_range      tstzrange generated always as
                    (tstzrange(start_at, start_at + make_interval(mins => duration_minutes))) stored,
  end_at          timestamptz generated always as
                    (start_at + make_interval(mins => duration_minutes)) stored,
  status          booking_status not null default 'pending',
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  -- ★ 關鍵：同一設計師、未取消的預約，時間範圍不得重疊。
  --   兩個請求同時搶同一格時，DB 會擋掉其中一個(拋 exclusion_violation)，
  --   不必在 application 層自己加鎖，天然防 race condition。
  constraint bookings_no_overlap exclude using gist (
    staff_id  with =,
    time_range with &&
  ) where (status <> 'cancelled')
);
create index on bookings(tenant_id, staff_id, start_at);
create index on bookings(tenant_id, member_id);
create trigger trg_booking_updated before update on bookings
  for each row execute function public.set_updated_at();

-- =============================================================
-- RLS：多租戶隔離
-- =============================================================
-- 取得目前登入後台使用者所屬的租戶。security definer 以繞過自身 RLS。
-- ★ 量大時建議改成讀 JWT custom claim(app_metadata.tenant_id)，
--   省去每筆 query 的子查詢成本。
create or replace function public.current_tenant_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select tenant_id from public.tenant_members where user_id = auth.uid();
$$;

-- 開啟 RLS
alter table tenants                       enable row level security;
alter table tenant_members                enable row level security;
alter table subscriptions                 enable row level security;
alter table staff                         enable row level security;
alter table service_categories            enable row level security;
alter table services                      enable row level security;
alter table staff_services                enable row level security;
alter table members                       enable row level security;
alter table staff_availability_rules      enable row level security;
alter table staff_availability_exceptions enable row level security;
alter table bookings                      enable row level security;

-- 後台使用者：只能存取自己租戶的資料(對絕大多數表一律 for all)
do $$
declare t text;
begin
  foreach t in array array[
    'subscriptions','staff','service_categories','services','staff_services',
    'members','staff_availability_rules','staff_availability_exceptions','bookings'
  ] loop
    execute format($f$
      create policy tenant_isolation on %I
        for all to authenticated
        using (tenant_id in (select public.current_tenant_ids()))
        with check (tenant_id in (select public.current_tenant_ids()));
    $f$, t);
  end loop;
end $$;

-- tenants 表本身
create policy tenant_self_read on tenants
  for select to authenticated
  using (id in (select public.current_tenant_ids()));
create policy tenant_member_self on tenant_members
  for select to authenticated
  using (user_id = auth.uid());

-- 公開預約頁(anon)：只讀 active 的服務與設計師，供前端渲染選單。
create policy public_read_services on services
  for select to anon using (is_active = true);
create policy public_read_staff on staff
  for select to anon using (is_active = true);
create policy public_read_staff_services on staff_services
  for select to anon using (true);
-- 注意：members / bookings / 時段 不開放 anon 直接讀寫，
--       公開操作一律走下方 RPC。

-- =============================================================
-- 內部函式：檢查某時段是否落在設計師可用範圍內
-- =============================================================
create or replace function public.is_slot_available(
  p_staff_id uuid,
  p_start_at timestamptz,
  p_duration_minutes int
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz       text;
  v_local_s  timestamp;   -- 當地時間(無時區)
  v_local_e  timestamp;
  v_date     date;
  v_dow      int;
  v_st       time;
  v_et       time;
  v_ok       boolean;
begin
  select t.timezone into v_tz
  from staff s join tenants t on t.id = s.tenant_id
  where s.id = p_staff_id;
  if v_tz is null then return false; end if;

  v_local_s := p_start_at at time zone v_tz;
  v_local_e := v_local_s + (p_duration_minutes * interval '1 minute');
  v_date := v_local_s::date;
  v_dow  := extract(dow from v_local_s)::int;
  v_st   := v_local_s::time;
  v_et   := v_local_e::time;

  -- 不跨日(沙龍預約不會跨午夜)
  if v_local_e::date <> v_date then return false; end if;

  -- 1) 必須被「規則班表」或「當日 extra」覆蓋
  v_ok := exists (
            select 1 from staff_availability_rules r
            where r.staff_id = p_staff_id and r.weekday = v_dow
              and r.start_time <= v_st and r.end_time >= v_et
          )
          or exists (
            select 1 from staff_availability_exceptions e
            where e.staff_id = p_staff_id and e.date = v_date and e.kind = 'extra'
              and coalesce(e.start_time, time '00:00') <= v_st
              and coalesce(e.end_time,   time '24:00') >= v_et
          );
  if not v_ok then return false; end if;

  -- 2) 不得落在任何 block 例外內
  if exists (
       select 1 from staff_availability_exceptions e
       where e.staff_id = p_staff_id and e.date = v_date and e.kind = 'block'
         and (e.start_time is null  -- 整天請假
              or (coalesce(e.start_time, time '00:00') < v_et
                  and coalesce(e.end_time, time '24:00') > v_st))
     ) then
    return false;
  end if;

  return true;
end $$;

-- =============================================================
-- 公開 RPC：建立預約(消費者用 anon key 呼叫)
-- =============================================================
-- security definer：以擁有者權限執行，內部自行驗證 tenant 範圍。
-- exclusion constraint 會在並發搶位時自動擋下，這裡轉成友善錯誤。
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
  v_member_id uuid;
  v_booking_id uuid;
begin
  -- 服務需屬於該租戶且啟用
  select duration_minutes into v_duration
  from services
  where id = p_service_id and tenant_id = p_tenant_id and is_active = true;
  if v_duration is null then
    raise exception 'service_not_found' using errcode = 'no_data_found';
  end if;

  -- 設計師需屬於該租戶、啟用、且能做此服務
  if not exists (
       select 1 from staff s
       join staff_services ss on ss.staff_id = s.id and ss.service_id = p_service_id
       where s.id = p_staff_id and s.tenant_id = p_tenant_id and s.is_active = true
     ) then
    raise exception 'staff_cannot_serve' using errcode = 'check_violation';
  end if;

  -- 必須在可用時段內
  if not public.is_slot_available(p_staff_id, p_start_at, v_duration) then
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;

  -- 會員 upsert(以同店電話為鍵)
  insert into members (tenant_id, name, phone, email)
  values (p_tenant_id, p_customer_name, p_customer_phone, p_customer_email)
  on conflict (tenant_id, phone)
  do update set name = excluded.name,
                email = coalesce(excluded.email, members.email)
  returning id into v_member_id;

  -- 建立預約；若同格被搶 → exclusion_violation
  begin
    insert into bookings (tenant_id, staff_id, service_id, member_id,
                          start_at, duration_minutes, status, note)
    values (p_tenant_id, p_staff_id, p_service_id, v_member_id,
            p_start_at, v_duration, 'pending', p_note)
    returning id into v_booking_id;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'unique_violation';
  end;

  return v_booking_id;
end $$;

-- 允許前端 anon 呼叫(僅此函式，不開放 bookings 表)
grant execute on function public.create_booking(
  uuid, uuid, uuid, timestamptz, text, text, text, text) to anon;

-- =============================================================
-- 查詢可預約時段：回傳某設計師某日、某服務時長的所有可約起始時間
-- =============================================================
-- 演算法：當日可用區間(規則 ∪ extra) − block − 既有預約，
--         再依 p_slot_minutes 步進切出落得下 service 時長的起點。
create or replace function public.get_available_slots(
  p_staff_id     uuid,
  p_service_id   uuid,
  p_date         date,
  p_slot_minutes int default 15   -- 預約起點的時間顆粒度
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
begin
  select t.timezone into v_tz
  from staff s join tenants t on t.id = s.tenant_id where s.id = p_staff_id;
  if v_tz is null then return; end if;

  select (duration_minutes * interval '1 minute') into v_dur
  from services where id = p_service_id;
  if v_dur is null then return; end if;

  -- 把當地 (date + time) 轉成 timestamptz 區間後彙整成 multirange
  select coalesce(range_agg(tstzrange(
           ((p_date + r.start_time) at time zone v_tz),
           ((p_date + r.end_time)   at time zone v_tz))), '{}')
    into v_avail
  from staff_availability_rules r
  where r.staff_id = p_staff_id and r.weekday = v_dow;

  -- 加上當日 extra
  select v_avail + coalesce(range_agg(tstzrange(
           ((p_date + coalesce(e.start_time, time '00:00')) at time zone v_tz),
           ((p_date + coalesce(e.end_time,   time '23:59')) at time zone v_tz))), '{}')
    into v_avail
  from staff_availability_exceptions e
  where e.staff_id = p_staff_id and e.date = p_date and e.kind = 'extra';

  -- block 例外
  select coalesce(range_agg(tstzrange(
           ((p_date + coalesce(e.start_time, time '00:00')) at time zone v_tz),
           ((p_date + coalesce(e.end_time,   time '23:59')) at time zone v_tz))), '{}')
    into v_blocks
  from staff_availability_exceptions e
  where e.staff_id = p_staff_id and e.date = p_date and e.kind = 'block';

  -- 既有未取消預約
  select coalesce(range_agg(b.time_range), '{}') into v_booked
  from bookings b
  where b.staff_id = p_staff_id and b.status <> 'cancelled'
    and b.start_at >= ((p_date) at time zone v_tz)
    and b.start_at <  ((p_date + 1) at time zone v_tz);

  v_free := v_avail - v_blocks - v_booked;

  -- 在每段剩餘空檔內，依顆粒度切出可放入 service 時長的起點
  for v_sub in select unnest(v_free) loop
    v_cursor := lower(v_sub);
    while v_cursor + v_dur <= upper(v_sub) loop
      return next v_cursor;
      v_cursor := v_cursor + (p_slot_minutes * interval '1 minute');
    end loop;
  end loop;
end $$;

grant execute on function public.get_available_slots(uuid, uuid, date, int) to anon;
