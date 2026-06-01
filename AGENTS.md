# AGENTS.md

> Codex / Claude / Aider / 任何 agentic coder 入口文件。

## TL;DR

讀這幾份就懂這專案:
1. [CLAUDE.md](./CLAUDE.md) — 一頁速覽 + 設計憲法
2. [docs/SPEC.md](./docs/SPEC.md) — 功能規格 + 已實作對照
3. [docs/SCHEMA.md](./docs/SCHEMA.md) — DB schema + RPC 速查
4. [docs/DEV.md](./docs/DEV.md) — 本機開發 + debug + 常用 curl

## 你能改什麼,不能改什麼

### 可以改 (請繼續做)
- 新 Vue page / composable
- 新 migration (連號 `00NN_*.sql`)
- 新 RPC (記得 SECURITY DEFINER + tenant 驗證 + grant)
- UI 樣式調整 (但別違反美學規則 — 見下)
- bug 修

### 不要改 (除非人類明確指示)
- `0001_booking_core.sql` 的 exclusion constraint
- `tenants` 表的 slug unique 限制
- RLS 開關 (一律 enabled)
- 金流流向 (情況 A,商家自有帳戶,平台不經手)
- 黑底白字按鈕 (user 明確禁止後台白字)

## 風格速查

| 區塊 | 風格 |
|------|------|
| 後台 (`/admin/*`) | 米黃 cream — `#f3eedd` 底 / `#fdfaf1` 卡 / Georgia headline / `#f5b945` accent |
| 前台 (`/`, `/book`, `/manage`) | Apple Liquid Glass — SF Pro / `.lg-*` utility classes |
| 月曆 | 月曆本身保留原 cream spec (user 親自設計過),不要改 |

## 任務工作流

1. 讀 `git log --oneline -20` 看最近進度
2. 看 `supabase/migrations/` 最大編號,推測當前 schema 狀態 (但**實際以 DB 真實情況為準**,用 service_role 查 schema)
3. 動寫之前查 SPEC.md 看該功能是否已有 / 是否還沒做
4. **跑前先做最小驗證** — curl 試 RPC、用 `pnpm dev` 在 demo-shop.lvh.me:3000 試 UI
5. 改完 commit message 用 [conventional commits](https://www.conventionalcommits.org/) 格式

## 不要假設的事

- 不要假設「migration 都已套用」— 人類常忘記跑,先 curl 驗證 schema
- 不要假設「`type="text"` 在 input 上」— Vue 沒寫 type 時 DOM 沒這 attribute,CSS selector 不認
- 不要假設「`Nuxt dev` 預設 listen IPv4」— 預設只 listen `[::1]`,要 `--host 0.0.0.0`

## 緊急 hotline

業主 = 唯一 stakeholder: winsonboy23@gmail.com
