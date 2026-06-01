# CLAUDE.md — Beauty Reservation Platform 專案指引

> 給未來任何 AI 助理 (Claude / Cursor / Copilot) 看的「快速上手」文件。
> 真實人類請看 [README.md](./README.md)。
>
> ⚠️ **任何新對話開頭請先讀 [STATUS.md](./STATUS.md)** — 那裡有此刻待辦 / 已完成 / 未跑的 migration。
> 本檔講設計原則,不講進度。

## 1. 一句話

多租戶 SaaS 美業預約系統。Nuxt 3 SSR + Supabase (Postgres 15 + RLS + Storage)。產品定位是「商家可被 Google 收錄的品牌專屬子網域預約頁」(對標夯客、神美、樂創約)。

## 2. 設計憲法

讀過 [docs/SPEC.md](./docs/SPEC.md) 與 [docs/SCHEMA.md](./docs/SCHEMA.md) 後再動程式碼。改動前請保留以下原則:

1. **多租戶安全**: 所有業務表都帶 `tenant_id` + RLS。**禁止繞過 RLS 寫前端**,寫入一律經:
   - 後台老闆: `authenticated` role + `tenant_isolation` policy (auto 限定 `tenant_id IN current_tenant_ids()`)
   - 前台消費者: `anon` role 透過 `SECURITY DEFINER` RPC (例 `create_booking`),**不可直接寫 bookings**
2. **預約並發保護壓在 DB 層** — `bookings` 用 `btree_gist` exclusion constraint 擋同設計師同時段重疊。Application 層不需要也不該再加鎖。**不要刪掉 exclusion constraint**。
3. **金流走「情況 A」** — 訂金匯款直接到商家自有銀行帳戶 (`tenants.bank_*`),平台不經手金流、不抽成 (法遵考量,平台無金流牌照)。**禁止改成代收代付**。
4. **`SECURITY DEFINER` RPC 都得自己驗 tenant 範圍** — 因為它跳過 RLS。任何新 RPC 加 tenant_id 參數時要在函式內檢查 (見 `create_booking` 範例)。
5. **`generated column` 必須 IMMUTABLE** — Postgres 對 `bookings.end_at` / `time_range` 這類 stored generated column 要求運算式為 immutable。`timestamptz + interval` 是 STABLE 所以包了一層 `public.ts_plus_minutes(ts, mins)` IMMUTABLE 函式繞過。**不要直接寫 `start_at + interval '1 minute' * x`**。

## 3. 技術棧

| 層 | 用什麼 | 備註 |
|----|--------|------|
| 框架 | Nuxt 3 (SSR) + Vue 3 + TypeScript | `nuxt.config.ts` 已開 `compatibilityDate: 2025-05-01` |
| DB | Supabase Postgres 15 | extensions: `btree_gist`, `pgcrypto`, `pg_cron` |
| Auth | Supabase Auth (email + password) | 後台用; 前台預約是 anon |
| Storage | Supabase Storage `portfolio` bucket | public read, tenant-scoped write |
| 部署 | Zeabur (規劃) | 子網域需 wildcard DNS,本機開發用 `*.lvh.me` (公開 wildcard → 127.0.0.1) |
| Email | (未做) | 預計接 Resend / Zeabur SMTP |
| 金流 (訂金) | 走商家自有綠界 / 藍新 | 平台不經手 |
| 訂閱 | 綠界定期定額 (台灣) / Paddle (海外) — 未接 | UI placeholder, 等接金流 |

## 4. 專案結構

```
.
├── CLAUDE.md                 ← 你正在讀
├── README.md                 ← 給人類看的快速指南
├── docs/
│   ├── SPEC.md               ← 功能規格、流程、決策原則
│   ├── SCHEMA.md             ← DB 表 / function / RPC 完整目錄
│   └── DEV.md                ← 本機開發、常用 curl、debug 撇步
├── nuxt.config.ts            ← `--host 0.0.0.0` for lvh.me; vite.allowedHosts
├── app.vue / error.vue       ← shell + 404
├── assets/css/liquid-glass.css ← 全域設計系統 (Apple LG / 米黃 admin)
├── composables/
│   ├── useBooking.ts         ← 包 3 個預約 RPC + 錯誤訊息映射
│   ├── useMyTenant.ts        ← 取登入老闆的店家 (一店一店家假設)
│   ├── usePlanStatus.ts      ← 取方案 + 用量, plan_status RPC
│   └── usePortfolio.ts       ← Supabase Storage 上傳 / publicUrl / remove
├── layouts/
│   ├── storefront.vue        ← 前台 (消費者) - Liquid Glass
│   └── admin.vue             ← 後台 - 米黃 cream 配色, 對齊月曆
├── middleware/
│   ├── tenant.global.ts      ← host → slug → tenant 解析
│   └── auth.ts               ← /admin/* 守衛
├── pages/
│   ├── index.vue             ← 店家品牌頁 / 平台 landing
│   ├── book.vue              ← 4-step 預約 (服務 → 加購 → 設計師 → 日期/時段 → 資料)
│   ├── manage/[id].vue       ← 客人 token 自助管理 (改期 / 取消)
│   └── admin/
│       ├── login.vue
│       ├── index.vue         ← 預約清單 (14 天 list view)
│       ├── calendar.vue      ← 月視圖網格 (cream + 米黃 spec)
│       ├── services/index.vue ← 服務 CRUD + 分類 + 加購 + 代表圖
│       ├── staff/index.vue   ← 員工列表
│       ├── staff/[id].vue    ← 員工編輯 + 服務指派 + 班表 + 作品集
│       ├── members/index.vue ← 會員列表 (黑名單 / 用量統計)
│       ├── members/[id].vue  ← 會員詳細 + 預約歷史
│       ├── billing.vue       ← 方案 + 用量
│       ├── reports.vue       ← 營收 / 員工業績 / 服務排行
│       └── settings.vue      ← 店家名稱 + slug + 銀行帳號
└── supabase/
    ├── migrations/0001..0012.sql ← schema (見 docs/SCHEMA.md)
    └── seed/0001_demo_owner.sql  ← demo tenant seed
```

## 5. 環境變數 (.env)

```bash
SUPABASE_URL=https://<ref>.supabase.co
SUPABASE_KEY=<anon JWT>                # 前端用
SUPABASE_SERVICE_ROLE_KEY=<service JWT> # webhook / 後端 only,別漏進 bundle
NUXT_PUBLIC_DEFAULT_TENANT_SLUG=demo-shop # dev fallback (生產應移除)
```

## 6. 本機開發

```bash
pnpm install
pnpm dev          # http://localhost:3000 + http://demo-shop.lvh.me:3000
```

**`pnpm dev` 已設 `--host 0.0.0.0`** — 因 Nuxt 預設只 listen `[::1]:3000` (IPv6),而 lvh.me 解析回 IPv4,沒這個 flag 子網域連不上。

## 7. 常見任務指南

- **新增業務表** → 寫到 `supabase/migrations/00NN_*.sql`,**包含 RLS enable + tenant_isolation policy + grant + 對應 anon read policy 若有**。對齊 0003_grants.sql 慣例。
- **新增 RPC** → SECURITY DEFINER,函式內驗 tenant_id;`grant execute to anon` (若需公開) 或 `to authenticated`。**用 `errcode` 拋語意錯誤**讓 [composables/useBooking.ts](./composables/useBooking.ts) 的 `ERROR_MESSAGES` 接住。
- **新增前端頁面** → 後台 `pages/admin/<name>.vue` + `definePageMeta({ middleware: 'auth', layout: 'admin' })`,前台 `pages/<name>.vue` + layout: 'storefront'。
- **改 storefront 樣式** → 用 [assets/css/liquid-glass.css](./assets/css/liquid-glass.css) 的 `.lg-*` 工具類 (lg-card / lg-btn / lg-input / lg-pill)。
- **改 admin 樣式** → 米黃 cream 風,**不要白底白字**;同調色板:`#f3eedd` (頁底) / `#fdfaf1` (卡片) / `#2b2b2b` (邊) / `#f5b945` (action accent) / `#c0392b` (danger)。

## 8. 任何 AI 助理動工前必做

1. **讀完 `docs/SPEC.md` 1/4 章「設計憲法」**  
2. **查最新 migration 數字**: `ls supabase/migrations/ | sort | tail -3`  
3. **確認當前 DB schema 狀態** (用 service_role curl Schema introspect):
   ```bash
   curl -s "$SUPABASE_URL/rest/v1/?select=" -H "apikey: $SR_KEY" -H "Authorization: Bearer $SR_KEY" | head
   ```
4. **動寫操作前先讀 RLS policies** (避免新功能漏掉 grant 或 policy)

## 9. 已知技術債

- [ ] storefront 沒處理 dark mode (測過 admin,沒測 storefront)
- [ ] 子網域邏輯本機 OK,生產還需 wildcard DNS + cert
- [ ] Email / LINE 通知未做 (等 Zeabur)
- [ ] 候補清單未做 (等通知)
- [ ] 試用到期降 free 的 cron 已寫,但沒實際驗證跑過
- [ ] 集點卡 / 優惠券 / 多分店 等 Phase 3 功能未做

## 10. 聯絡

業主 = 唯一開發者: winsonboy23@gmail.com

---
*文件版本: 2026-06-01 · 配合 schema migration 0012*
