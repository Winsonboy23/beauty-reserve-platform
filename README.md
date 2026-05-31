# Beauty Reserve Platform

美業 SaaS 預約系統 — Nuxt 3 + Supabase。

## Stack

- **Frontend**: Nuxt 3 (SSR for SEO)
- **Database / Auth**: Supabase (PostgreSQL 15 + RLS)
- **預約並發保護**: PostgreSQL `btree_gist` exclusion constraint (DB 層,非 application 層)

## 目錄結構

```
.
├── composables/useBooking.ts           # 包 supabase RPC 的前端 hook
├── layouts/
│   ├── storefront.vue                  # 前台 (消費者預約)
│   └── admin.vue                       # 後台 (店家管理)
├── middleware/
│   ├── tenant.global.ts                # 解析店家 (單店 demo 用 env)
│   └── auth.ts                         # /admin/* 路由守衛
├── pages/                              # (待補)
├── supabase/migrations/
│   ├── 0001_booking_core.sql           # 多租戶 + RLS + 預約核心
│   └── 0002_deposit_and_any_staff.sql  # 訂金 + 不指定設計師
└── nuxt.config.ts
```

## Setup

1. **複製 env**: `cp .env.example .env` 後填入 Supabase URL / anon key。
2. **跑 migration** (Supabase Dashboard → SQL Editor):
   - 先貼 `supabase/migrations/0001_booking_core.sql` 執行。
   - 再貼 `supabase/migrations/0002_deposit_and_any_staff.sql` 執行。
   - **順序不可顛倒** (0002 依賴 0001 的表)。
3. **啟用 pg_cron** (Supabase Dashboard → Database → Extensions):
   ```sql
   create extension if not exists pg_cron;
   select cron.schedule('release-holds','*/5 * * * *',
                        'select public.cleanup_expired_holds()');
   ```
   否則未付訂金的預約會永久卡住時段。
4. **安裝依賴 + 跑開發伺服器**:
   ```bash
   pnpm install
   pnpm dev
   ```

## 第一輪範圍 (MVP demo)

- [x] 專案 scaffolding (Nuxt + Supabase module + layouts + middleware)
- [x] Migrations 就位
- [ ] 後台登入頁 (`/admin/login`)
- [ ] 後台服務 CRUD (`/admin/services`)
- [ ] 後台員工 CRUD + 班表 (`/admin/staff`)
- [ ] 後台日曆 (`/admin`)
- [ ] 前台預約流程 (`/book`)

之後再做: 會員管理、報表、LINE、線上即時金流。

## 重要原則

- **金流 v1**: 訂金人工轉帳,`hold_expires_at` = 24 小時 (0002 SQL 已是 24h)。
- **不代收代付**: 商家綁自有綠界/藍新帳戶,平台只收訂閱費。
- **多租戶**: 所有業務表都帶 `tenant_id` + RLS, **不能信任前端帶的 tenant_id**, 後台寫入依 `auth.uid()` → `tenant_members` 解析。
