-- =============================================================
-- 0019 — 24h 提醒 + LINE webhook 綁定
-- =============================================================
-- 兩個獨立功能,合在同一個 migration 是因為都用 0014 的 LINE 設定。
--
-- 1. 預約前 24h 提醒
--    pg_cron 每 30 分鐘呼叫 dispatch_pending_reminders,
--    該函式找出「24h 內 (準確: 23.5-24.5h 窗口)」且尚未寄過提醒的 bookings,
--    透過 net.http_post 打到我們的 /api/notify/booking-reminder。
--    每筆 booking idempotent 由 notification_log (channel='cron', kind='reminder_24h_dispatched')
--    管,避免 cron 跑兩次寄兩次。
--    應用端的 Email/LINE log 是各自 channel + kind='reminder_24h'。
--
-- 2. LINE webhook
--    要驗證 X-Line-Signature 需要 channel secret,加 tenants.line_channel_secret。
--    line_pending_binding 表暫存「客人加好友還沒給電話」的 user_id。
-- =============================================================

create extension if not exists pg_net;

-- tenants: 加 channel_secret 給 webhook 驗 signature
alter table public.tenants
  add column line_channel_secret text;

-- =============================================================
-- platform_settings — 平台層級的配置 (僅一行)
--   notification_webhook_base_url: 24h 提醒 cron 要打的 URL 前綴
--   reminder_dispatch_secret:     pg_cron 與 server route 共用的 secret
-- =============================================================
create table public.platform_settings (
  id smallint primary key default 1 check (id = 1),
  notification_webhook_base_url text,
  reminder_dispatch_secret text not null default encode(gen_random_bytes(24), 'hex'),
  updated_at timestamptz not null default now()
);

insert into public.platform_settings (id) values (1) on conflict do nothing;

-- 鎖死: 只開放 service_role
grant select, update on public.platform_settings to service_role;
revoke all on public.platform_settings from public, anon, authenticated;

-- =============================================================
-- pending_reminder_bookings — 找出需要寄 24h 提醒的預約
-- =============================================================
create or replace function public.pending_reminder_bookings()
returns table (booking_id uuid)
language sql stable security definer set search_path = public as $$
  select b.id
  from bookings b
  where b.status in ('confirmed', 'pending')
    and b.start_at between (now() + interval '23.5 hours')
                      and (now() + interval '24.5 hours')
    and not exists (
      select 1 from notification_log n
      where n.booking_id = b.id
        and n.kind = 'reminder_24h_dispatched'
    );
$$;

-- =============================================================
-- dispatch_pending_reminders — pg_cron 呼叫此函式
-- =============================================================
create or replace function public.dispatch_pending_reminders()
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_base text;
  v_secret text;
  v_booking_id uuid;
  v_tenant_id uuid;
  v_count int := 0;
begin
  select notification_webhook_base_url, reminder_dispatch_secret
    into v_base, v_secret
  from platform_settings where id = 1;
  if v_base is null or length(v_base) = 0 then
    return 0;
  end if;

  for v_booking_id in select booking_id from public.pending_reminder_bookings()
  loop
    select tenant_id into v_tenant_id from bookings where id = v_booking_id;
    -- 寫 dispatched log (idempotent + tracking)
    insert into notification_log (tenant_id, booking_id, channel, kind, status)
    values (v_tenant_id, v_booking_id, 'cron', 'reminder_24h_dispatched', 'queued')
    on conflict (booking_id, channel, kind) do nothing;

    -- 異步 HTTP POST
    perform net.http_post(
      url := v_base || '/api/notify/booking-reminder',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'X-Dispatch-Secret', v_secret
      ),
      body := jsonb_build_object('bookingId', v_booking_id)
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

-- 排程 (僅當 pg_cron 已啟用才會成功)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'dispatch-reminders') then
      perform cron.unschedule('dispatch-reminders');
    end if;
    perform cron.schedule(
      'dispatch-reminders',
      '*/30 * * * *',
      $cmd$ select public.dispatch_pending_reminders() $cmd$
    );
  end if;
end $$;

-- =============================================================
-- LINE webhook 用的暫存表
-- 客人加 OA → follow event 我們存 user_id (沒電話可綁定);
-- 之後 message event 含電話 → 找到 → 綁 member.line_user_id + 刪暫存
-- =============================================================
create table public.line_pending_binding (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  line_user_id text not null,
  created_at timestamptz not null default now(),
  unique (tenant_id, line_user_id)
);

alter table public.line_pending_binding enable row level security;
-- 只給 service_role (webhook 寫,後台不需要看)
grant select, insert, update, delete on public.line_pending_binding to service_role;

-- =============================================================
-- bind_line_user — webhook 收到電話 message 後呼叫
--   tenant_id + phone + line_user_id → 找 member → 設 line_user_id
-- =============================================================
create or replace function public.bind_line_user(
  p_tenant_id uuid,
  p_phone text,
  p_line_user_id text
) returns table (member_id uuid, was_existing boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_member_id uuid;
  v_existing_line text;
begin
  select id, line_user_id into v_member_id, v_existing_line
  from members where tenant_id = p_tenant_id and phone = p_phone;

  if v_member_id is null then
    -- 沒有對應 member → 建一個空殼 (僅紀錄 LINE 綁定,沒姓名)
    insert into members (tenant_id, name, phone, line_user_id)
    values (p_tenant_id, '(LINE 綁定)', p_phone, p_line_user_id)
    returning id into v_member_id;
    return query select v_member_id, false;
  end if;

  -- 若該 member 已綁不同 line_user_id, 覆蓋 (最後一次操作為準)
  update members set line_user_id = p_line_user_id where id = v_member_id;
  return query select v_member_id, true;
end $$;

grant execute on function public.bind_line_user(uuid, text, text) to service_role;

-- =============================================================
-- 更新 tenant_line_settings_set 以同時收 channel_secret
-- (0014 版本的簽名變動,先 drop 再 create)
-- =============================================================
drop function if exists public.tenant_line_settings_set(uuid, text, text);

create or replace function public.tenant_line_settings_set(
  p_tenant_id    uuid,
  p_channel_id   text,
  p_access_token text,
  p_channel_secret text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from tenant_members
    where tenant_id = p_tenant_id and user_id = auth.uid()
  ) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;

  update tenants
  set line_channel_id = nullif(trim(p_channel_id), ''),
      line_channel_access_token = nullif(trim(p_access_token), ''),
      line_channel_secret = coalesce(nullif(trim(p_channel_secret), ''), line_channel_secret)
  where id = p_tenant_id;
end $$;

grant execute on function public.tenant_line_settings_set(uuid, text, text, text) to authenticated;

-- 更新 status 函式也回傳 has_secret
drop function if exists public.tenant_line_settings_status(uuid);

create or replace function public.tenant_line_settings_status(p_tenant_id uuid)
returns table (
  has_channel boolean,
  has_token boolean,
  has_secret boolean,
  channel_id text,
  msgs_used_this_month int
)
language sql stable security definer set search_path = public as $$
  select
    line_channel_id is not null as has_channel,
    line_channel_access_token is not null as has_token,
    line_channel_secret is not null as has_secret,
    line_channel_id,
    line_msgs_used_this_month
  from tenants
  where id = p_tenant_id
    and id in (select tenant_id from tenant_members where user_id = auth.uid());
$$;

grant execute on function public.tenant_line_settings_status(uuid) to authenticated;

-- =============================================================
-- 透過 channel_id 找 tenant (webhook 用)
-- =============================================================
create or replace function public.tenant_by_line_channel(p_channel_id text)
returns table (
  tenant_id uuid,
  channel_secret text,
  access_token text
)
language sql stable security definer set search_path = public as $$
  select id, line_channel_secret, line_channel_access_token
  from tenants where line_channel_id = p_channel_id;
$$;

revoke all on function public.tenant_by_line_channel(text) from public, anon, authenticated;
grant execute on function public.tenant_by_line_channel(text) to service_role;
