-- =============================================================
-- 0006 — 排程 cleanup_expired_holds 每 5 分鐘跑一次
-- =============================================================
-- 前置: 必須先在 Supabase Dashboard → Database → Extensions 啟用 pg_cron。
-- (UI 上搜 'pg_cron' 切 Enable, 或下面那行 SQL 也可,
--  但建議走 UI 因為 Supabase 內部需要做額外設定)
--
-- 跑完這支後,bookings 表 hold_expires_at 過期且仍 deposit_status='pending'
-- 的預約會自動轉成 cancelled,把 slot 釋放給其他客人。
-- =============================================================

create extension if not exists pg_cron;

-- 移除舊排程 (重跑此 migration 才不會疊加)
do $$ begin
  if exists (select 1 from cron.job where jobname = 'release-holds') then
    perform cron.unschedule('release-holds');
  end if;
end $$;

-- 每 5 分鐘跑一次
select cron.schedule(
  'release-holds',
  '*/5 * * * *',
  $$ select public.cleanup_expired_holds() $$
);

-- 驗證: 查 schedule 是否存在
-- select jobname, schedule, command from cron.job where jobname = 'release-holds';
