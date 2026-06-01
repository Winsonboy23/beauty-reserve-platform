-- =============================================================
-- 0004 — 店家銀行帳號 (轉帳訂金用)
-- =============================================================
-- v1 金流走「人工轉帳」: 客人按下預約後,系統需告知要匯到哪。
-- 帳號資訊存在 tenants 表上,前台預約成功頁讀取顯示。
--
-- 注意法遵: 此欄位儲存的是「店家自己的」銀行帳號 (情況 A,平台不經手金流);
-- 客人匯款直接進店家帳戶,平台只是把資訊顯示給客人。
-- =============================================================

alter table public.tenants
  add column bank_name            text,         -- 例: 國泰世華 / 中信 (含分行更佳)
  add column bank_account_no      text,         -- 帳號數字
  add column bank_account_holder  text,         -- 戶名
  add column bank_transfer_note   text;         -- 額外說明 (給客人看的提示)

-- anon 已在 0003 的 public_read_tenants policy 允許讀取 tenants;
-- 這幾個欄位會跟著被公開讀到,這是預期行為 (預約頁需要)。
-- 若未來想限縮敏感欄位,可改用 SECURITY DEFINER RPC 回傳 tenant 公開資訊。
