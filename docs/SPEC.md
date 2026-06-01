# SPEC — 功能規格 / 流程 / 決策

> 對照 features 規劃,把已實作 / 未實作標清楚。供任何 AI 助理 / 接手工程師參考。

---

## 1. 設計憲法 (一定要遵守)

### 1.1 多租戶隔離
- 所有業務表帶 `tenant_id`,RLS enabled
- 後台老闆透過 `authenticated` JWT + `tenant_isolation` policy 自動限定
- 前台消費者 (anon) **不直接讀寫表**,一律透過 SECURITY DEFINER RPC

### 1.2 預約並發保護
- `bookings` 有 `exclude using gist (staff_id with =, time_range with &&) where status <> 'cancelled'`
- 兩個請求同時搶同格 → DB 自動擋一個,拋 `exclusion_violation`
- RPC `create_booking` 把它轉成 `slot_taken` 拋給前端
- **不要用 application 層的 lock / SELECT FOR UPDATE 取代,因為 DB 約束更安全**

### 1.3 時段資料模型 (兩層)
1. `staff_availability_rules` — 每週固定班 (weekday + start/end time, 店家當地時區)
2. `staff_availability_exceptions` — 特定日期的 `block` (請假) / `extra` (加開)
- `is_slot_available()` 函式: 必須在 rules ∪ extras 內 AND 不在 blocks AND 不跨日

### 1.4 金流走「情況 A」
- 訂金匯款進**商家自有**綠界/藍新帳戶,**平台不經手**
- 平台只收訂閱費 (未來綠界定期定額)
- `tenants.bank_*` 欄位是商家自己的帳戶,顯示在預約成功頁
- 法遵: 平台無金流牌照不能代收代付,**絕對不要改成情況 B**

### 1.5 時區
- `tenants.timezone` (default 'Asia/Taipei') 是店家當地時區
- 時段比對用 `at time zone v_tz` 換算; 跨時區店家也能用同一支 RPC

---

## 2. 已實作功能 (對照 features.md)

### Phase 1 — 核心

| 功能 | 對應檔案 | 狀態 |
|------|----------|------|
| 線上預約表單 | `pages/book.vue` | ✅ |
| 時段管理 (rules + exceptions) | `pages/admin/staff/[id].vue` | ✅ |
| DB 層衝突偵測 | 0001 exclusion constraint | ✅ |
| 預約狀態流程 | enum `booking_status` | ✅ pending/confirmed/completed/cancelled/no_show |
| 後台日曆視圖 | `pages/admin/calendar.vue` | ✅ 月視圖 (米黃 cream 配色) |
| 後台預約清單 | `pages/admin/index.vue` | ✅ 14 天 list |
| 防爽約: 黑名單 | `migrations/0005`, members.is_blacklisted | ✅ |
| 防爽約: 自動上限 | — | ❌ 還沒做 |
| 多人員排班 | `pages/admin/staff/*.vue` | ✅ |
| 等候清單 | — | ❌ (等通知系統) |
| 預約改期自助 | `pages/manage/[id].vue` + token | ✅ |
| 會員系統 (後台) | `pages/admin/members/*.vue` | ✅ |
| 會員系統 (客人端登入 + 歷史) | — | ❌ |
| 作品集照片 | `staff_portfolio` 表 + Storage | ✅ |
| 服務代表圖 | `services.image_path` | ✅ |
| 服務分類 | `service_categories` 表 + UI | ✅ |
| 加購項目 | `services.is_addon` + `bookings.addon_ids` | ✅ |
| 評價系統 | — | ❌ |
| 偏好標籤 | `members.tags` | ✅ |

### Phase 2 — 通知 & 收款

| 功能 | 狀態 |
|------|------|
| Email 通知 | ❌ 等 Zeabur 部署 |
| LINE OA | ❌ |
| 預約前提醒 | ❌ |
| 取消/改期通知 | ❌ |
| 線上預付訂金 (人工轉帳) | ✅ |
| 即時線上金流 | ❌ (md 規格走人工轉帳) |
| 現場結帳記錄 | ✅ `bookings.actual_amount` |
| 發票/收據 | ❌ |
| 優惠券/折扣碼 | ❌ |

### Phase 3 — 數據 & 進階

| 功能 | 狀態 |
|------|------|
| 營收報表 | ✅ `tenant_report` RPC + `pages/admin/reports.vue` |
| 員工業績 | ✅ |
| 服務熱門度 | ✅ |
| 回客率 | ✅ (new vs returning) |
| 再行銷推播 | ❌ (Phase 3 未來) |
| 員工打卡/換班 | ❌ |
| 多分店 | ❌ (schema 上 tenant 可以,但 owner 對 tenant 是 1:1) |
| 集點卡 / 點數 / 生日禮券 | ❌ |
| API 開放 | ❌ |

### SaaS 基礎架構

| 功能 | 狀態 |
|------|------|
| 多租戶 RLS | ✅ |
| 預約並發保護 | ✅ |
| 訂閱方案 DB + UI | ✅ 顯示+用量,實際收費 placeholder |
| 14 天試用降級 cron | ✅ `auto_downgrade_trials` (沒實測) |
| 自訂子網域 + SEO | ✅ host 解析 + useSeoMeta + 404 |
| Slug 編輯 | ✅ `pages/admin/settings.vue` |

---

## 3. 預約流程 (核心)

### 3.1 客人預約 (/book)
```
1. middleware/tenant.global.ts 從 host 解析 tenant
2. 載入 services + staff_services + staff_portfolio
3. UI 步驟:
   主服務 → (加購 multi) → 設計師 (or 不指定) → 日期 → 時段 → 填資料
4. 送出:
   - 指定設計師 → create_booking RPC
   - 不指定     → create_booking_any RPC
5. RPC 流程:
   plan_limit → service 驗證 → staff 能做此服務 → addon 驗證
     → is_slot_available → 黑名單 → upsert member → 寫 bookings
   並發衝突 → exclusion_violation → 拋 slot_taken
6. 成功頁顯示: 短編號、銀行帳號(若需訂金)、管理連結
```

### 3.2 客人自助改期 (/manage/[id]?t=token)
```
1. get_booking_for_manage(id, token) 拉資料 (含 tenant 銀行)
2. 改期: 選日期 + 新時段 → reschedule_booking
   - 驗 token、status 可改、is_slot_available → update start_at
3. 取消: cancel_booking_by_token → status='cancelled'
```

### 3.3 後台處理 (老闆)
```
1. 預約進來 → status='pending', deposit_status='pending' (若需訂金)
2. 客人轉帳 → 老闆在後台點「標訂金已付」
   → status: pending→confirmed, deposit_status: pending→paid
3. 客人到店服務完 → 點「完成」 → 跳 prompt 輸入 actual_amount
   → status='completed' + actual_amount 寫入
4. 客人沒來 → 點「爽約」 → status='no_show'
   (爽約 ≥3 次 UI 提示老闆考慮列黑名單)
5. pg_cron 每 5 分鐘跑 cleanup_expired_holds:
   24h 未付訂金的預約 → status='cancelled' 自動釋放
```

---

## 4. 方案限制

| 項目 | 免費 | 基本 ($599) | 專業 ($1290) |
|------|------|-------------|--------------|
| 月預約 | 15 | ∞ | ∞ |
| 會員 | 50 | ∞ | ∞ |
| 服務 | 5 | ∞ | ∞ |
| 員工 | 1 | 2 | ∞ |
| 訂金收取 | ❌ | ✅ | ✅ |
| 自訂子網域 | ❌ | ✅ | ✅ |
| LINE 通知 | 0 | 200/月 | 1000/月 |

**試用期 14 天以 pro 上限算**,到期 `auto_downgrade_trials()` 把 status 改 active + plan='free'。

**限制執行點**:
- `create_booking` RPC: 月預約超限拋 `plan_limit_exceeded`
- `create_booking` RPC: 若 free 方案,訂金強制 0
- 前端 (`/admin/services`, `/admin/staff`): 觸頂時 disable 新增鈕,顯示「升級提示」

---

## 5. 風險 / 注意

### 5.1 已知 footgun
- **`generated column` immutability**: `bookings.end_at` / `time_range` 不能改用 `timestamptz + interval` (STABLE),必須走 `ts_plus_minutes` IMMUTABLE wrapper
- **RPC 簽名變動**: `create_booking` 跟 `create_booking_any` 改過好幾次 (加 addon_ids、manage_token 回傳),改動後 `useBooking.ts` 要同步
- **子網域本機開發**: `pnpm dev` 必須 `--host 0.0.0.0` 才能 IPv4 listen,讓 lvh.me 解到 127.0.0.1 連得上
- **storage policies 用 tenant_id 路徑前綴**: `<tenant_id>/...`,寫入時 `(storage.foldername(name))[1]::uuid in current_tenant_ids()` 檢查

### 5.2 不能繞過的東西
- DB 層 exclusion constraint (不要 disable)
- RLS (不要 disable; 寫測試也別跑 service_role 來省事)
- 金流情況 A (不要改成代收代付)
- `SECURITY DEFINER` RPC 內部 tenant 驗證 (不要省略)

---

## 6. 版本歷程 (重大變動)

| migration | 內容 |
|-----------|------|
| 0001 | 核心 schema + RLS + 預約 RPC (含 ts_plus_minutes IMMUTABLE) |
| 0002 | 訂金 + 不指定設計師 + cleanup_expired_holds |
| 0003 | PostgREST grants (anon / authenticated / service_role) |
| 0004 | tenants.bank_* |
| 0005 | members.is_blacklisted + RPC 加檢查 |
| 0006 | pg_cron 排程 |
| 0007 | bookings.manage_token + 自助改期 RPCs |
| 0008 | services.image_path + staff_portfolio + storage bucket |
| 0009 | plan_limits / tenant_usage / plan_status + RPC 加上限檢查 |
| 0010 | tenants.slug 格式 check (3-30, lowercase, alnum + hyphen) |
| 0011 | services.is_addon + bookings.addon_ids + bookings.actual_amount + 重寫 create_booking + tenant_report RPC |
| 0012 | fix tenant_report (member_visits 漏 join) |
