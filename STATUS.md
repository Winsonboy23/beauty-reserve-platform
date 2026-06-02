# STATUS — 開新對話必讀

> 最後更新: 2026-06-02
> 任何 AI / 接手工程師: **先讀這份**,再讀 [CLAUDE.md](./CLAUDE.md) / [docs/](./docs/)

---

## 🚦 當前狀態

**部署階段**: 本機開發中,還沒上線。  
**最新 migration**: `0018_points_redemption.sql`  
**Git remote**: https://github.com/Winsonboy23/beauty-reserve-platform (main 分支)  
**Demo URL**: 本機 `http://demo-shop.lvh.me:3000`

---

## ⚠️ 必須先處理的待辦 (給業主)

### 1. 跑沒跑的 migration

```
0014_line_oa.sql                    ← 業主已跑 ✅
0015_customer_accounts.sql          ← 業主已跑 ✅ (客人登入)
0016_coupons.sql                    ← 業主已跑 ✅ (優惠券)
0017_loyalty_points.sql             ← 業主已跑 ✅ (集點)
0018_points_redemption.sql          ← 待跑 (點數兌換 + bookings 加 points_used / points_discount)
```

到 Supabase Dashboard → SQL Editor 貼 → Run。**任何 AI 動 LINE 通知功能前要先確認 0014 已套用** (用 service_role curl `notify_booking_payload` RPC 試試,有回資料就代表 0014 跑了)。

### 2. 外部服務金鑰 (有就填,沒填就走 dev mode)

寫進 `.env`:

| 變數 | 來源 | 沒填的後果 |
|------|------|------------|
| `RESEND_API_KEY` | https://resend.com 註冊 → API Keys | Email 不真寄,只 console.log |
| `EMAIL_FROM` | 你的寄件 email | 預設 `onboarding@resend.dev` |
| LINE 設定 | https://developers.line.biz 申請 → token 進 `/admin/settings` UI 設,不放 env | LINE 不真寄 |

---

## ✅ 已完成 (commit 摘要)

### Phase 1 — 核心
- 預約核心 schema + RLS + 並發保護 (0001)
- 訂金 / 不指定設計師 (0002)
- PostgREST grants (0003)
- 銀行帳號 + admin/settings (0004)
- 黑名單 (0005)
- pg_cron schedule (0006)
- manage_token + 自助改期/取消 (0007)
- 作品集 + 服務代表圖 + Storage bucket (0008)
- 方案限制 + 試用降級 + /admin/billing (0009)
- slug 格式 + 子網域 host 解析 + /admin/settings slug 編輯 (0010)
- 服務分類 + 加購 + actual_amount + 報表 RPC (0011)
- 報表 SQL bug 修 (0012)

### Phase 2 — 通知 (新加)
- Email 整合 (Resend) — server route + 模板 + idempotent log (0013)
- LINE OA 整合 — push API + tenant token + member 綁定 (0014)
- 客人端會員系統 — /login + /my + RLS + JWT 改期 / 取消 (0015)
- 優惠券 / 折扣碼 — /admin/coupons + /book 即時驗證 (0016)

### UI / 設計
- 後台米黃 cream 配色 (對齊月曆視覺)
- 前台 Liquid Glass (對齊 iOS 26 美學)
- error.vue 404 處理
- 報表頁 /admin/reports

### Onboarding 文件
- CLAUDE.md / AGENTS.md / .cursorrules
- docs/SPEC.md / SCHEMA.md / DEV.md

---

## 🔨 接下來的開發任務 (依優先序)

### 下一個準備做 (next)

**集點卡 / 點數系統**
- 完成預約累積點數 (1 元 1 點 或 自訂比率)
- 達門檻可兌換折扣或免費服務
- /my 顯示「我的點數」+ 兌換歷史
- 規模: 中大 (3-4 輪對話)

### 排隊中

| 項目 | 規模 | 備註 |
|------|------|------|
| Resend API key 接好真實寄送驗證 | 小 | 業主自己設定 |
| LINE OA 申請接好真實推播驗證 | 小 | 業主自己設定 |
| 部署到 Zeabur + 真實 domain | 中 | 上線前必做 |
| 訂閱金流 (綠界定期定額) | 大 | 平台收費必要 |
| 發票 / 收據 | 中 | 法遵 |

### 已決定不做 / 延後

- ❌ 取消次數自動上限 (黑名單已手動)
- ❌ 評分系統
- ❌ 生日禮券
- ❌ 員工打卡 / 換班
- ❌ 耗材庫存
- ❌ 候補名單 (等 LINE webhook)
- ❌ 預約前 24h 自動提醒 (等 cron + LINE 接通)
- ❌ storefront dark mode

---

## 🛠 已知技術債

1. **`tenants.line_channel_access_token` 暫時沒做 column-level access** — anon 透過 `public_read_tenants` 還能 select 它,但目前 token 都還是 null 所以沒洩。生產前必須 revoke column-level 或拆 view (見 0014 migration 內的 TODO 註記)
2. **storefront 沒測 dark mode** — admin 已強制 light, /book /index /manage 在 dark mode 下可能有對比問題
3. **試用到期降級 cron 沒驗證真的有跑** — pg_cron schedule 已建立但要等 14 天才能自然測
4. **LINE user_id 手動綁定** — v1 是老闆從 LINE OAM 後台貼;v2 規劃 LINE webhook 自動綁
5. **沒自動化測試** — 全靠 curl 手測

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

## 📚 文件導讀

| 文件 | 看什麼 |
|------|--------|
| **STATUS.md** (本檔) | 此刻的狀態 + 待辦 |
| [CLAUDE.md](./CLAUDE.md) | 設計憲法 + 不可違反規則 |
| [docs/SPEC.md](./docs/SPEC.md) | 功能規格 + 已實作對照 |
| [docs/SCHEMA.md](./docs/SCHEMA.md) | DB tables / RPCs 速查 |
| [docs/DEV.md](./docs/DEV.md) | curl debug + 常見錯誤 |
| [AGENTS.md](./AGENTS.md) | 給通用 AI agent 入口 |
| [README.md](./README.md) | 給人類的簡介 |

---

## 💬 給未來 AI session 的開場提示

接手任何任務前:

1. **先確認 DB 狀態** — 用 service_role curl 查 schema,別假設 migration 都跑了 (見 [docs/DEV.md](./docs/DEV.md) 「Schema introspect」段)
2. **先看 [CLAUDE.md](./CLAUDE.md) §2 設計憲法** — 多租戶 / 預約並發 / 金流情況A 等是死線,不可違反
3. **看本檔 §「接下來的開發任務」** — 別自己挑題目;業主決定優先序
4. **手測流程**: `pnpm dev` → 開 `http://demo-shop.lvh.me:3000`,**不要只跑 curl 就說功能 OK**

業主帳號: winsonboy23@gmail.com (登入後台用)
