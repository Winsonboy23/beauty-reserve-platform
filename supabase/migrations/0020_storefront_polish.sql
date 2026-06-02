-- =============================================================
-- 0020 — 前台收尾: LINE OA 加好友連結
-- =============================================================
-- tenants.line_oa_share_url: 業主從 LINE Manager 拿到的「加好友」分享連結
-- 形如 https://line.me/R/ti/p/@xxxxxx
-- 顯示在 /book 成功頁 / /my 當作 CTA, 帶客人去加 OA。
-- =============================================================

alter table public.tenants
  add column line_oa_share_url text;

-- 公開讀: anon 透過 public_read_tenants 已能讀,不用另開 policy
