# DEV — 本機開發、debug、常用指令

## Setup

```bash
git clone https://github.com/Winsonboy23/beauty-reserve-platform.git
cd beauty-reserve-platform
pnpm install

# .env
cp .env.example .env
# 填 SUPABASE_URL / SUPABASE_KEY (anon) / SUPABASE_SERVICE_ROLE_KEY
# 開發用 NUXT_PUBLIC_DEFAULT_TENANT_SLUG=demo-shop
```

## 跑

```bash
pnpm dev
# http://localhost:3000              ← 平台 (fallback demo-shop)
# http://demo-shop.lvh.me:3000       ← 店家品牌頁
# http://<slug>.lvh.me:3000          ← 任何已建立的 tenant
# http://localhost:3000/admin/login  ← 後台
```

> `lvh.me` 是公開 wildcard DNS,`*.lvh.me` 都解析到 `127.0.0.1`。  
> Nuxt dev 預設只 listen `[::1]`(IPv6),package.json 已加 `--host 0.0.0.0` 才能 IPv4 也聽。

## 跑 migration

進 Supabase Dashboard → SQL Editor → 新 query → 貼 `supabase/migrations/00NN_*.sql` 整支 → Run。

**順序敏感**: 從沒跑過的最小編號開始,逐支跑。`drop function if exists` 等寫法是 idempotent 安全。

## 環境變數

| 變數 | 用途 |
|------|------|
| `SUPABASE_URL` | `https://<ref>.supabase.co` |
| `SUPABASE_KEY` | anon JWT (前端用) |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role JWT (server only,**不可** bundle 進 client) |
| `NUXT_PUBLIC_DEFAULT_TENANT_SLUG` | dev fallback,生產拿掉 |

## 常用 curl debug

```bash
# 自家 schema introspect
SR='<service_role_key>'
URL='https://<ref>.supabase.co/rest/v1'

# 看某 tenant 預約
curl -s "$URL/bookings?select=id,start_at,status&order=start_at" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" | python3 -m json.tool

# 模擬客人建立預約 (用 anon)
ANON='<anon_key>'
curl -s -X POST "$URL/rpc/create_booking" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{
    "p_tenant_id":"<uuid>",
    "p_staff_id":"<uuid>",
    "p_service_id":"<uuid>",
    "p_start_at":"2026-06-08T13:00:00+08:00",
    "p_customer_name":"測試","p_customer_phone":"0900000000",
    "p_addon_ids":[]
  }'

# 試報表
curl -s -X POST "$URL/rpc/tenant_report" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" -H "Content-Type: application/json" \
  -d '{"p_tenant_id":"<uuid>","p_days":30}' | python3 -m json.tool
```

## 模擬不同身分 (產生 JWT)

不用知道 user 密碼,用 service_role + Admin API mint magic-link 取 access_token:

```bash
SR='...'
curl -s -X POST "https://<ref>.supabase.co/auth/v1/admin/generate_link" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" -H "Content-Type: application/json" \
  -d '{"type":"magiclink","email":"<user_email>"}' | jq .

# 訪問 action_link, 從 Location header 拿 access_token (跟 # 之後的 fragment)
curl -sv "<action_link>" 2>&1 | grep -i "^< location:" | head -1
```

## RLS / Permission debug

如果某 SELECT 回 401 / 403:

1. 先用 service_role 確認資料真的在
2. 再用 anon 試 — 缺 `grant select to anon` 會 401 (即使 RLS policy 允許)
3. 再帶 user JWT 試 — 缺 tenant_isolation policy 或 user 不屬於該 tenant

**典型 trap**: 加新表後,migration 漏掉 `enable row level security` + policy + grant。對齊 `0003_grants.sql`。

## 常見錯誤對照

| code / message | 真實原因 |
|----------------|----------|
| `42P17 generation expression is not immutable` | timestamptz + interval 是 STABLE,要走 ts_plus_minutes IMMUTABLE wrapper |
| `42703 column "X" does not exist` | 某支 migration 沒跑,or 跑到中途失敗 |
| `42P01 missing FROM-clause entry for table "b"` | CTE 引用沒在 FROM 的別名 (見 0012 修 tenant_report) |
| `23505 unique_violation` (slug) | 子網域撞名 |
| `exclusion_violation` | 預約撞時段 → RPC 轉成 `slot_taken` |
| HTTP 401 from REST | 缺 grant; 看 hint 通常會說 "Grant the required privileges..." |
| ERR_CONNECTION_REFUSED on demo-shop.lvh.me:3000 | Nuxt 沒 bind IPv4 → 確認 package.json dev script 有 `--host 0.0.0.0` |
| Vite "Blocked request. This host" | 加 host 到 `nuxt.config.ts` 的 `vite.server.allowedHosts` |

## 直接測 storage upload

```bash
# 建一個 1x1 PNG
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0P\x0f\x00\x00\x04\x05\x01\x01\x12n\xd5\xe5\x00\x00\x00\x00IEND\xaeB`\x82' > /tmp/p.png

TENANT='<uuid>'
SVC='<uuid>'
curl -s -X POST \
  "https://<ref>.supabase.co/storage/v1/object/portfolio/$TENANT/services/$SVC/main.png?upsert=true" \
  -H "apikey: $SR" -H "Authorization: Bearer $SR" \
  -H "Content-Type: image/png" \
  --data-binary "@/tmp/p.png"
```

## 修改後台外觀 (cream 配色)

- Page bg: `#f3eedd`
- Card bg: `#fdfaf1`
- Border: `1px solid #2b2b2b`, radius `14px`
- Headline: Georgia serif
- Body: SF Pro / PingFang TC
- Action (橘黃 fill): `#f5b945` + 黑字 `#1a1a1a`
- Danger: outlined red `#c0392b` on pale red `#fde2dd`

**禁止**: 黑底白字按鈕 (user explicitly forbidden)

## 修改前台外觀 (Liquid Glass)

用 `assets/css/liquid-glass.css` 的 utility classes:
- `.lg-card`, `.lg-card-tight`
- `.lg-btn`, `.lg-btn-filled`, `.lg-btn-secondary`, `.lg-btn-plain`, `.lg-btn-danger`, `.lg-btn-sm`
- `.lg-input`, `.lg-textarea`, `.lg-select`, `.lg-field`, `.lg-field-label`
- `.lg-pill`, `.lg-pill-accent`, `.lg-pill-success`, `.lg-pill-warning`, `.lg-pill-danger`
- `.lg-title1`..`.lg-title3`, `.lg-headline`, `.lg-body`, `.lg-callout`, `.lg-subhead`, `.lg-footnote`, `.lg-caption`
- `.glass`, `.glass-strong`, `.glass-tinted`

CSS vars: `--accent (#007aff)`, `--r-card (16px)`, `--r-pill (999px)`, `--s-N (4/8/12/16/24/32/48/64)` 等。

## 部署到 Zeabur (規劃)

1. 加環境變數 `SUPABASE_URL`, `SUPABASE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
2. **拿掉 `NUXT_PUBLIC_DEFAULT_TENANT_SLUG`** (生產不要 fallback)
3. DNS: wildcard A `*.mybeauty.app → Zeabur IP` (或 CNAME)
4. SSL: 建議 Cloudflare 代管 wildcard cert (Zeabur 默 HTTP-01 不支援 wildcard)
5. Nuxt build: `pnpm build` → `node .output/server/index.mjs`

## 已知 footgun (一定要避開)

1. 別在 `<input>` 不寫 `type` (CSS selector `input[type="text"]` 不會 match)
2. 別在 admin layout 用白文字 (user explicitly forbidden)
3. 別繞過 RLS 直接從前端寫 bookings (走 RPC)
4. 別改 exclusion constraint (預約並發保護核心)
5. 別忘記新表的 RLS + grant + policy 三件套 (對齊 0003)
6. 別忘記 `pnpm dev` 的 `--host 0.0.0.0` 不能拿掉
