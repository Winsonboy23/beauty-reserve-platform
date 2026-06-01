# SCHEMA — DB 物件目錄

> 跟 `supabase/migrations/0001..0012.sql` 對齊的速查表。
> 改動 schema 一律新 migration `00NN_*.sql`,不要 patch 舊檔。

---

## 1. Tables

### tenants — 店家
```
id              uuid pk
name            text
slug            text unique         -- 用於子網域 + URL
timezone        text default 'Asia/Taipei'
plan            plan_tier default 'free'
bank_name           text  -- 訂金匯款資訊 (0004)
bank_account_no     text
bank_account_holder text
bank_transfer_note  text
created_at / updated_at
```
**RLS**: 後台 `authenticated` 只能讀寫自己 tenant; anon `public_read_tenants` 全表可讀 (storefront 需依 slug 查)。
**Constraint**: `tenant_slug_format` — 3-30, lowercase, `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (0010)

### tenant_members — 後台使用者 ↔ 店家
```
tenant_id  uuid → tenants
user_id    uuid → auth.users
role       text  -- 'owner' | 'manager' | 'staff' (目前只有 owner)
primary key (tenant_id, user_id)
```

### subscriptions
```
tenant_id     uuid unique → tenants
plan          plan_tier
status        subscription_status  -- trialing / active / past_due / paused / canceled
trial_ends_at timestamptz
current_period_end timestamptz
provider / provider_ref text   -- 'ecpay' | 'newebpay' | 'paddle'
```

### staff — 設計師 / 員工
```
id, tenant_id, user_id (nullable, 給未來登入)
name, is_active
```

### service_categories — 服務分類
```
id, tenant_id, name, sort_order
```

### services — 服務項目
```
id, tenant_id, category_id (nullable)
name, duration_minutes, price
deposit_amount  numeric(10,2) nullable   -- 0002
is_active boolean
is_addon boolean default false           -- 0011, true = 不能單獨預約,只能搭主服務
image_path text                           -- 0008 storage path
```
**Constraint**: `duration_minutes > 0`, `price >= 0`

### staff_services — 員工能做哪些服務 (m:n)
```
tenant_id, staff_id, service_id
primary key (staff_id, service_id)
```

### members — 會員 (消費者)
```
id, tenant_id, name, phone, email
note, tags text[]
is_blacklisted boolean default false   -- 0005
unique (tenant_id, phone)   -- 同店電話為自然鍵
```

### staff_availability_rules — 週固定班表
```
id, tenant_id, staff_id
weekday smallint (0=日 ~ 6=六)
start_time / end_time time   -- 店家當地時區
```

### staff_availability_exceptions — 例外日
```
id, tenant_id, staff_id, date
kind availability_kind  -- 'block' (請假) | 'extra' (加開)
start_time / end_time time (nullable, null = 整天)
reason text
```

### bookings — 預約 (核心)
```
id, tenant_id, staff_id, service_id, member_id
start_at timestamptz
duration_minutes int
time_range tstzrange  GENERATED ALWAYS AS (
  tstzrange(start_at, public.ts_plus_minutes(start_at, duration_minutes))
) STORED
end_at timestamptz GENERATED ALWAYS AS (
  public.ts_plus_minutes(start_at, duration_minutes)
) STORED

status booking_status  -- pending / confirmed / completed / cancelled / no_show
note text

-- 訂金 (0002)
deposit_amount numeric default 0
deposit_status deposit_status  -- none / pending / paid / refunded / forfeited
payment_provider / payment_ref text
paid_at timestamptz
hold_expires_at timestamptz   -- 24 hr 後 cleanup_expired_holds 釋放

-- 自助管理 (0007)
manage_token text not null default encode(gen_random_bytes(16),'hex')

-- 加購 + 結帳 (0011)
addon_ids uuid[] default '{}'
actual_amount numeric(10,2)
```
**Key constraint**: `bookings_no_overlap` exclusion using gist `(staff_id with =, time_range with &&) where (status <> 'cancelled')`

### staff_portfolio — 設計師作品集 (0008)
```
id, tenant_id, staff_id
storage_path text         -- portfolio bucket 相對路徑
caption text
sort_order int
```

---

## 2. Enums

| Type | Values |
|------|--------|
| `plan_tier` | `free`, `basic`, `pro` |
| `subscription_status` | `trialing`, `active`, `past_due`, `paused`, `canceled` |
| `booking_status` | `pending`, `confirmed`, `completed`, `cancelled`, `no_show` |
| `availability_kind` | `block`, `extra` |
| `deposit_status` | `none`, `pending`, `paid`, `refunded`, `forfeited` |

---

## 3. Functions (內部 helpers)

### `ts_plus_minutes(ts timestamptz, mins int) → timestamptz` (IMMUTABLE)
時間加分鐘的 IMMUTABLE wrapper,讓 `bookings.end_at` / `time_range` generated column 能用。

### `current_tenant_ids() → setof uuid` (SECURITY DEFINER)
查當前 `auth.uid()` 屬於哪些 tenant; RLS policy `tenant_isolation` 用它。

### `is_slot_available(staff_id, start_at, duration_minutes) → boolean` (SECURITY DEFINER)
判斷某時段是否在設計師的 rules ∪ extras 內,且不在 block。

### `set_updated_at()` trigger function
通用 `updated_at = now()`。

---

## 4. RPCs (給前端用)

### Public (anon callable)

#### `create_booking(p_tenant_id, p_staff_id, p_service_id, p_start_at, p_customer_name, p_customer_phone, p_customer_email, p_note, p_addon_ids) → table(booking_id uuid, manage_token text)`
完整流程: plan_limit → service 驗 → staff 能做 → addon 驗 → slot 可用 → 黑名單 → upsert member → insert bookings。 拋 `slot_taken` / `slot_unavailable` / `staff_cannot_serve` / `service_not_found` / `addon_invalid` / `member_blacklisted` / `plan_limit_exceeded`。

#### `create_booking_any(p_tenant_id, p_service_id, p_start_at, ..., p_addon_ids, out booking_id, out staff_id, out manage_token)`
同上,但自動指派最少預約的 staff。 拋 `no_staff_available` 等。

#### `get_available_slots(p_staff_id, p_service_id, p_date, p_slot_minutes, p_addon_ids) → setof timestamptz`
回傳該日可預約起始時間 (依 service + addons 總時長算)。

#### `get_booking_for_manage(p_booking_id, p_token) → table(... including tenant bank info ...)`
拿 (id, token) 取自己的預約資料 (含店家銀行帳號,給匯款區用)。

#### `reschedule_booking(p_booking_id, p_token, p_new_start_at) → void`
改期。 拋 `booking_not_found` / `booking_not_modifiable` / `slot_unavailable` / `slot_taken`。

#### `cancel_booking_by_token(p_booking_id, p_token) → void`
取消。

### Authenticated only

#### `tenant_usage(tenant_id) → table(plan, status, trial_ends_at, bookings_this_month, services, staff, members)`
即時用量。試用期會回 plan='pro' 以套用 pro 上限。

#### `plan_limits(plan) → table(...)` (IMMUTABLE)
方案配置表 (硬編碼)。

#### `plan_status(tenant_id) → json`
給前端一次撈完用量 + 上限。

#### `tenant_report(tenant_id, days default 30) → json`
報表: revenue / bookings_by_status / staff perf / service perf / new vs returning。

### Backend only (用 service_role 呼叫)

#### `cleanup_expired_holds() → int`
釋放 24h 未付訂金的預約 (status=pending → cancelled)。pg_cron `*/5 * * * *`。

#### `mark_deposit_paid(p_booking_id, p_provider, p_provider_ref)`
給金流 webhook 用 (目前手動轉帳沒用)。

#### `auto_downgrade_trials() → int`
試用過期 trialing → active+free。pg_cron `0 3 * * *`。

---

## 5. RLS Policies

統一規則:
- `tenant_isolation` on 所有業務表 — `tenant_id IN (select current_tenant_ids())` for all authenticated
- `public_read_services` / `_staff` / `_staff_services` / `_tenants` / `_staff_portfolio` — `to anon using (...)` 
- bookings / members / availability 表 — anon 不直接讀寫,走 RPC

## 6. Storage

### Bucket: `portfolio` (public read)
**Path 約定**: `<tenant_id>/services/<service_id>/main.<ext>` 或 `<tenant_id>/staff/<staff_id>/<random>.<ext>`

**Policies on storage.objects**:
- `portfolio_public_read` — `for select to anon, authenticated using (bucket_id = 'portfolio')`
- `portfolio_tenant_insert/update/delete` — `(storage.foldername(name))[1]::uuid in (select current_tenant_ids())`

## 7. pg_cron 排程

| job name | schedule | command |
|----------|----------|---------|
| `release-holds` | `*/5 * * * *` | `select cleanup_expired_holds()` |
| `auto-downgrade-trials` | `0 3 * * *` | `select auto_downgrade_trials()` |

---

## 8. 重要 invariants

- 任何 `services.is_addon = true` 的服務,在 /book step 1 隱藏,只在 step 1.5 加購區出現
- `bookings.duration_minutes` 必須包含主服務 + 所有 addons 時長
- `bookings.addon_ids` 元素必須都是 `services.is_addon = true` 且 `is_active = true`
- `bookings.actual_amount` 只在 status='completed' 時填寫
- `tenants.slug` 不能用保留字: `www, app, admin, api, auth, static, cdn, mail, email, dashboard, docs, help, support, blog, status, localhost` (前端 + DB 雙重檢查)
- `bookings_no_overlap` exclusion 保證同 staff 同時段不會雙重預約 (status='cancelled' 不算)
