-- =============================================================
-- 0013 — notification_log
-- =============================================================
-- 記錄哪些通知已經寄過,避免重複。Email / LINE / SMS 共用此表。
--
-- 設計:
--   unique(booking_id, channel, kind) — 同一筆預約 + 同管道 + 同事件只能寄一次
--   channel: 'email' | 'line' | 'sms'
--   kind:    'booking_created' | 'deposit_paid' | 'reminder_24h' | ...
-- =============================================================

create table public.notification_log (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  booking_id      uuid not null references public.bookings(id) on delete cascade,
  channel         text not null,       -- 'email' | 'line' | 'sms'
  kind            text not null,       -- 'booking_created' | ...
  recipient       text,                -- email address / LINE user id / phone
  status          text not null default 'sent', -- 'sent' | 'failed' | 'queued'
  provider_ref    text,                -- 外部服務的訊息 id
  error_message   text,
  created_at      timestamptz not null default now(),
  unique (booking_id, channel, kind)
);

create index on public.notification_log(tenant_id, created_at desc);
create index on public.notification_log(booking_id);

alter table public.notification_log enable row level security;

-- 老闆讀自己店的記錄
create policy tenant_isolation on public.notification_log
  for all to authenticated
  using (tenant_id in (select public.current_tenant_ids()))
  with check (tenant_id in (select public.current_tenant_ids()));

grant select, insert, update on public.notification_log to authenticated;
grant select, insert, update, delete on public.notification_log to service_role;
-- anon 不需直接寫,通知由 server route 用 service_role 操作
