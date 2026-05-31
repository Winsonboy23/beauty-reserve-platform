-- =============================================================
-- 0003 — PostgREST role grants
-- =============================================================
-- 補上 0001/0002 漏的 table-level GRANT。
-- Supabase 規則: 要存取一張表必須同時通過 (a) GRANT 與 (b) RLS policy。
-- 我們的 0001/0002 已寫好 policy, 這裡補 GRANT。
--
-- 因為建專案時取消了「Automatically expose new tables」, 預設不會自動 grant,
-- 所以新表都要手動 grant; 之後新增表記得在同一個 migration 一併加。
-- =============================================================

-- ---------- authenticated (後台老闆/員工) ----------
-- 所有業務表都讓 authenticated 可 CRUD; RLS 的 tenant_isolation 會擋跨租戶。
grant select, insert, update, delete on
  tenants,
  tenant_members,
  subscriptions,
  staff,
  service_categories,
  services,
  staff_services,
  members,
  staff_availability_rules,
  staff_availability_exceptions,
  bookings
to authenticated;

-- 給 sequence 用 (gen_random_uuid 不需要,但若之後有 serial 會需要)
grant usage on all sequences in schema public to authenticated;

-- ---------- anon (公開預約頁的消費者) ----------
-- 只開唯讀,僅限公開資訊:
--   services / staff / staff_services 已在 0001 寫了 public_read_* policy
--   tenants 補一條 anon 可依 slug 找店家的 policy + grant
grant select on
  public.services,
  public.staff,
  public.staff_services,
  public.tenants
to anon;

-- 前台需要靠 slug 解析出 tenant_id; 不開放會導致 storefront 無法載入店家資訊。
-- 這條 policy 只暴露非敏感欄位 (id / name / slug / timezone),
-- 若擔心被掃描全部商家清單,之後可改成 RPC + 限縮欄位。
create policy public_read_tenants on tenants
  for select to anon using (true);
