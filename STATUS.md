# STATUS — 開新對話必讀

> 最後更新: 2026-06-02
> 任何 AI / 接手工程師: **先讀這份**,再讀 [CLAUDE.md](./CLAUDE.md) / [docs/](./docs/)

---

## 🚦 當前狀態

**部署階段**: 本機開發中,還沒上線。
**最新 migration**: `0020_storefront_polish.sql`
**Git remote**: https://github.com/Winsonboy23/beauty-reserve-platform (main 分支)
**Demo URL**: 本機 `http://demo-shop.lvh.me:3000`
**前台**: 已收尾完整 (除 dark mode 業主明確不做)
**後台**: 業主日常運營 + 設定全完整

---

## ⚠️ 必須先處理的待辦 (給業主)

### 1. 跑 migration

到 Supabase Dashboard → SQL Editor 貼 → Run:

```
0001-0013                           ← 業主已跑 ✅
0014_line_oa.sql                    ← 業主已跑 ✅
0015_customer_accounts.sql          ← 業主已跑 ✅
0016_coupons.sql                    ← 業主已跑 ✅
0017_loyalty_points.sql             ← 業主已跑 ✅
0018_points_redemption.sql          ← 業主已跑 ✅
0019_reminders_and_line_webhook.sql ← 業主已跑 ✅
0020_storefront_polish.sql          ← 待跑 (line_oa_share_url 欄位)
```

### 2. 外部服務金鑰 (有就填,沒填就走 dev mode)

寫進 `.env`:

| 變數 | 來源 | 沒填的後果 |
|------|------|------------|
| `RESEND_API_KEY` | https://resend.com 註冊 → API Keys | Email 不真寄,只 console.log |
| `EMAIL_FROM` | 你的寄件 email | 預設 `onboarding@resend.dev` |
| LINE 設定 | https://developers.line.biz → token + secret 進 `/admin/settings` UI 設,不放 env | LINE 不真寄 |

### 3. 生產環境上線後

1. SQL: `update platform_settings set notification_webhook_base_url = 'https://your-domain.com' where id = 1;`
2. 各 tenant 的 LINE channel 設好 secret → 到 LINE Developers 把 webhook URL 設成 `https://your-domain.com/api/webhook/line/<channel_id>`
3. 移除 `NUXT_PUBLIC_DEFAULT_TENANT_SLUG` (生產不要 fallback)

---

## ✅ 已完成 (依 migration 編號)

### 0001-0003 核心
- 多租戶 schema + RLS + 預約並發保護 (`bookings_no_overlap` GiST exclusion)
- 訂金 + 不指定設計師 + cleanup_expired_holds
- PostgREST grants (anon / authenticated / service_role)

### 0004-0010 平台基礎
- 銀行帳號設定 + 訂金人工轉帳
- 黑名單機制
- pg_cron schedule
- manage_token + 自助改期 / 取消
- 作品集 + 服務代表圖 + Storage bucket
- 方案限制 + 試用期降級 + /admin/billing
- slug 格式 + 子網域 host 解析 + SEO meta

### 0011 服務升級
- 服務分類 (`service_categories`)
- 加購項目 (`services.is_addon` + `bookings.addon_ids`)
- 現場結帳記錄 (`bookings.actual_amount`)
- 報表 RPC (`tenant_report`)
- /admin/reports 頁

### 0013-0014 通知基礎
- `notification_log` 跨通道 idempotency
- Resend Email 整合 (有 dev mode fallback)
- LINE Messaging API push 整合

### 0015 客人端會員
- `members.user_id` 綁定 auth.users
- /login + /my 客人 dashboard
- 自助改期 / 取消 (JWT)

### 0016 優惠券
- coupons + coupon_uses 表 + validate_coupon RPC
- /admin/coupons CRUD
- /book 即時驗證 + 套用

### 0017-0018 集點
- 賺點 (預約完成自動加點)
- 點數兌換 (`/book` 用點數折抵,登入才顯示)
- /admin/members/[id] 手動調整
- /my 點數歷史

### 0019 通知收尾
- 訂金已付通知 (Email + LINE)
- 預約完成通知 (Email + LINE) — 含點數累積提示
- 24h 提醒 — pg_cron + pg_net 自動 dispatch + 後台手動觸發 button
- LINE webhook 自動綁定 — 客人加 OA 傳電話 → 自動 claim user_id

### 0020 前台收尾
- `/services` 公開服務列表 (按分類分組 + SEO)
- `/book` step 1 按分類分組
- `/staff` 設計師列表 + `/staff/[id]` 個人頁 (含 JSON-LD `Person` schema)
- `/my` 會員儀表板 (等級 / 累積消費 / 造訪 / 點數)
- LINE OA 加好友 CTA (/book 成功頁 + /my)

### UI / 設計
- 後台米黃 cream 配色 (對齊月曆視覺)
- 前台 Apple Liquid Glass (SF Pro / 同心圓角)
- error.vue 404 處理

### Onboarding 文件
- CLAUDE.md / AGENTS.md / .cursorrules
- docs/SPEC.md / SCHEMA.md / DEV.md

---

## 🔨 接下來能做的任務

### 後台運營效率
| 項目 | 規模 | 為什麼想做 |
|------|------|----------|
| 多選預約批次操作 (一鍵完成 / 取消) | 小 | 老闆每天處理大量預約 |
| 預約 / 會員 / 報表 CSV 匯出 | 小 | 做帳必備 |
| 進階報表 (趨勢圖 / 客單價 / 同期比較) | 中 | 看出生意起伏 |
| 預約日曆拖拉改約 | 中 | UX 痛點 |
| 寄推播給特定客人 (行銷工具) | 中 | 留客 |
| 員工排班衝突警示 | 小 | 防呆 |

### 上線必要
| 項目 | 規模 | 業主說 |
|------|------|------|
| **部署到 Zeabur + 真實 domain + SSL** | 中 | pending |
| **訂閱金流 (綠界定期定額)** | 大 | pending |
| **電子發票** | 中 | pending |

### 規模較大長期項目
- 多分店連鎖
- API 開放給商家
- AI 加購模組 (智慧排班 / 流失預測)

### ❌ 已決定不做
- 取消次數自動上限 / 評分系統 / 生日禮券
- 員工打卡 / 換班 / 耗材庫存
- 候補名單 / storefront dark mode

---

## 🛠 已知技術債

1. **`tenants.line_channel_*` 對 anon 還能讀** — 0014 的 TODO; 生產前要 revoke column-level 或拆 view
2. **storefront 沒測 dark mode** — admin 已強制 light, 前台未測
3. **pg_cron + pg_net schedules 沒實測** — 本機開不到,要在生產驗
4. **沒自動化測試** — 全靠 curl 手測
5. **試用到期降級 cron 沒實測** — 要等 14 天

---

## 🗂 開發環境

```bash
git clone https://github.com/Winsonboy23/beauty-reserve-platform
cd beauty-reserve-platform
pnpm install
cp .env.example .env  # 填 SUPABASE_URL / KEY
pnpm dev              # http://localhost:3000 + http://demo-shop.lvh.me:3000
```

**注意**: `pnpm dev` 已加 `--host 0.0.0.0`,別拿掉 (lvh.me 子網域需要 IPv4 listen)。

---

## 📚 路徑速查

### 前台 (storefront)
| 路徑 | 內容 |
|------|------|
| `/` | 店家品牌頁 / 平台 landing |
| `/book` | 5-step 預約 (服務分類 → 加購 → 設計師 → 日期/時段 → 資料 + 優惠碼 + 點數) |
| `/services` | 服務列表 (按分類) |
| `/staff` | 設計師團隊 |
| `/staff/[id]` | 設計師個人頁 + 作品集 + 提供服務 |
| `/login` | 客人 sign in / sign up |
| `/my` | 會員 dashboard + 預約歷史 + 點數 |
| `/manage/[id]?t=token` | 訪客自助改期 / 取消 |

### 後台 (admin)
| 路徑 | 內容 |
|------|------|
| `/admin/login` | 業主登入 |
| `/admin` | 預約清單 (14 天) |
| `/admin/calendar` | 月視圖 (cream) |
| `/admin/services` | 服務 + 分類 + 加購 CRUD |
| `/admin/staff` | 員工列表 |
| `/admin/staff/[id]` | 員工 + 班表 + 服務指派 + 作品集 |
| `/admin/members` | 會員列表 |
| `/admin/members/[id]` | 會員詳細 + 點數 + LINE 綁定 |
| `/admin/coupons` | 優惠券 CRUD |
| `/admin/reports` | 報表 |
| `/admin/billing` | 方案 + 用量 |
| `/admin/settings` | 店家資訊 / slug / 銀行帳號 / LINE / 集點 |

### API endpoints (server)
| 路徑 | 觸發 |
|------|------|
| `/api/notify/booking-created` | /book 預約成功 |
| `/api/notify/deposit-paid` | 業主標訂金已付 |
| `/api/notify/booking-completed` | 業主標完成 |
| `/api/notify/booking-reminder` | pg_cron 自動 / 業主手動 |
| `/api/notify/booking-line` | /book 預約成功 (LINE) |
| `/api/webhook/line/[channel]` | LINE 平台推 events |

---

## 💬 給未來 AI session 的開場提示

接手任何任務前:

1. **先確認 DB 狀態** — 用 service_role curl 查 schema,別假設 migration 都跑了
2. **先看 [CLAUDE.md](./CLAUDE.md) §2 設計憲法** — 多租戶 / 預約並發 / 金流情況A 等是死線
3. **看本檔 §「接下來能做的任務」** — 業主決定優先序
4. **手測流程**: `pnpm dev` → 開 `http://demo-shop.lvh.me:3000`,**不要只跑 curl 就說功能 OK**

業主帳號: winsonboy23@gmail.com
