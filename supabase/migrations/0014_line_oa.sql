-- =============================================================
-- 0014 — LINE OA 整合欄位
-- =============================================================
-- 每店家有自己的 LINE OA, 自己的 channel access token。
-- 平台不共用 token (跟金流情況 A 一樣 — 平台只是工具,不經手商家認證資料)。
--
-- 客人 LINE user_id 要 store 在 members 才能推播。
-- v1 由老闆手動貼 (從 LINE Official Account Manager 後台拿)。
-- v2 將透過 LINE webhook (客人加好友) 自動綁定。
-- =============================================================

-- tenants: 店家自家 LINE OA 設定
alter table public.tenants
  add column line_channel_id text,
  add column line_channel_access_token text,
  add column line_msgs_used_this_month int not null default 0;

-- members: 該客人的 LINE user_id (該店家專屬,因為不同店家 OA 有不同 user_id)
alter table public.members
  add column line_user_id text;

create index on public.members(tenant_id, line_user_id) where line_user_id is not null;

-- ⚠️ 重要: LINE token 是 secret, 不能讓 anon 讀到
-- 0003 的 public_read_tenants policy 允許 anon 全表讀。要新增一個過濾,把
-- line_* 欄位排除。最簡單做法: 提供一支 RPC 給 anon 拿「公開的 tenant 資訊」,
-- 然後 tighten public_read_tenants 只允許 select id, slug, name, timezone 等公開欄位。
--
-- 暫時做法: 不擋 (因為 line_channel_access_token 還沒設都是 null);
-- 等真實上線前,加 column-level grant 或拆 view 把 token 隔離。

-- TODO before production: column-level permission for line_channel_access_token
-- revoke select(line_channel_access_token) on public.tenants from anon;

create or replace function public.tenant_line_settings_set(
  p_tenant_id uuid,
  p_channel_id text,
  p_access_token text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- 確保呼叫者是該 tenant 的 member
  if not exists (
    select 1 from tenant_members
    where tenant_id = p_tenant_id and user_id = auth.uid()
  ) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;

  update tenants
  set line_channel_id = nullif(trim(p_channel_id), ''),
      line_channel_access_token = nullif(trim(p_access_token), '')
  where id = p_tenant_id;
end $$;

grant execute on function public.tenant_line_settings_set(uuid, text, text) to authenticated;

-- 給後台讀「是否已設定 LINE」用 (不回傳 token 本身, 安全)
create or replace function public.tenant_line_settings_status(p_tenant_id uuid)
returns table (
  has_channel boolean,
  has_token boolean,
  channel_id text,
  msgs_used_this_month int
)
language sql stable security definer set search_path = public as $$
  select
    line_channel_id is not null as has_channel,
    line_channel_access_token is not null as has_token,
    line_channel_id,
    line_msgs_used_this_month
  from tenants
  where id = p_tenant_id
    and id in (select tenant_id from tenant_members where user_id = auth.uid());
$$;

grant execute on function public.tenant_line_settings_status(uuid) to authenticated;

-- =============================================================
-- 預約創建後,server route 要拿 LINE 通知所需資料:
--   tenant 的 token + member 的 line_user_id
-- 因為 token 是 secret, 不能透過 anon RPC 拿。
-- → 提供一支只給 service_role 用的 helper RPC。
-- =============================================================
create or replace function public.notify_booking_payload(p_booking_id uuid)
returns table (
  -- booking 摘要
  short_ref text,
  start_at_local text,
  duration_minutes int,
  deposit_amount numeric,
  deposit_status text,
  service_name text,
  staff_name text,
  customer_name text,
  customer_email text,
  member_line_user_id text,
  -- tenant 端 + bank
  tenant_id uuid,
  tenant_name text,
  tenant_timezone text,
  tenant_bank_name text,
  tenant_bank_account_no text,
  tenant_bank_account_holder text,
  tenant_bank_transfer_note text,
  tenant_line_channel_id text,
  tenant_line_channel_access_token text,
  manage_token text
)
language sql stable security definer set search_path = public as $$
  select
    upper(substr(b.id::text, 1, 6)) as short_ref,
    to_char(b.start_at at time zone t.timezone, 'YYYY-MM-DD HH24:MI') as start_at_local,
    b.duration_minutes,
    b.deposit_amount,
    b.deposit_status::text,
    sv.name as service_name,
    s.name as staff_name,
    m.name as customer_name,
    m.email as customer_email,
    m.line_user_id as member_line_user_id,
    t.id, t.name, t.timezone,
    t.bank_name, t.bank_account_no, t.bank_account_holder, t.bank_transfer_note,
    t.line_channel_id, t.line_channel_access_token,
    b.manage_token
  from bookings b
  join services sv on sv.id = b.service_id
  join staff s on s.id = b.staff_id
  join members m on m.id = b.member_id
  join tenants t on t.id = b.tenant_id
  where b.id = p_booking_id;
$$;

-- 只給 service_role; anon / authenticated 不可叫 (會拿到 token)
revoke all on function public.notify_booking_payload(uuid) from public, anon, authenticated;
grant execute on function public.notify_booking_payload(uuid) to service_role;
