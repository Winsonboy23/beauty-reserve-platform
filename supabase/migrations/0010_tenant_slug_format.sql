-- =============================================================
-- 0010 — tenants.slug 格式約束
-- =============================================================
-- 為了當子網域用,slug 必須:
--   1. 3–30 字
--   2. 只能小寫字母、數字、連字號
--   3. 不能以 hyphen 開頭/結尾
--
-- 保留字 (admin/api/www/...) 由 application 層擋 (在 settings 頁加檢查),
-- DB 不擋是因為現有 demo-shop 已存在,加 reserved 清單會與保留字升級難。
-- =============================================================

alter table public.tenants
  add constraint tenant_slug_format
  check (
    char_length(slug) between 3 and 30
    and slug ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
  );
