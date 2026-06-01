<script setup lang="ts">
// 後台 - 方案 / 訂閱
// 顯示當前方案、用量、試用倒數;升級按鈕暫時連 LINE/Email,正式上線再接金流
definePageMeta({ middleware: 'auth', layout: 'admin' })

const { tenant, load: loadTenant } = useMyTenant()
const { status, load, trialDaysLeft, usage } = usePlanStatus()
await loadTenant()
if (tenant.value) await load(tenant.value.id, true)

interface PlanCard {
  key: 'free' | 'basic' | 'pro'
  name: string
  price: string
  highlights: string[]
}
const PLANS: PlanCard[] = [
  { key: 'free',  name: '免費',  price: '$0', highlights: [
    '每月預約 15 筆','會員 50 人','服務 5 項','員工 1 人','Email 通知','基礎品牌頁'
  ]},
  { key: 'basic', name: '基本',  price: '$599 / 月', highlights: [
    '無限預約','無限會員 / 服務','員工 2 人','LINE 通知 200 則 / 月',
    '線上訂金 (0 抽成)','自訂子網域','基本報表'
  ]},
  { key: 'pro',   name: '專業',  price: '$1,290 / 月', highlights: [
    '無限員工','LINE 通知 1,000 則 / 月','進階報表',
    '再行銷自動推播','會員集點卡','優先客服'
  ]},
]

function fmtLimit(used: number, limit: number) {
  return limit < 0 ? `${used} / 無限` : `${used} / ${limit}`
}
function fmtTrial(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('zh-TW', { year: 'numeric', month: '2-digit', day: '2-digit' })
}
</script>

<template>
  <div>
    <h1>方案與用量</h1>

    <section v-if="status" class="card">
      <div class="cur">
        <div>
          <span class="muted small">目前方案</span>
          <div class="plan-name">
            {{ ({ free: '免費方案', basic: '基本方案', pro: '專業方案' } as any)[status.plan] }}
            <span :class="['badge', 'st-' + status.status]">
              {{ ({ trialing: '試用中', active: '使用中', past_due: '逾期', paused: '暫停', canceled: '已取消' } as any)[status.status] }}
            </span>
          </div>
        </div>
        <div v-if="status.status === 'trialing'">
          <span class="muted small">試用到期</span>
          <div class="plan-name">{{ fmtTrial(status.trial_ends_at) }}
            <span v-if="trialDaysLeft !== null" class="muted small">(剩 {{ trialDaysLeft }} 天)</span>
          </div>
        </div>
      </div>

      <h3>本月用量</h3>
      <div class="usage">
        <div v-for="row in [
          { label: '本月預約', kind: 'bookings_this_month' },
          { label: '服務項目', kind: 'services' },
          { label: '員工人數', kind: 'staff' },
          { label: '會員人數', kind: 'members' },
        ]" :key="row.kind" class="usage-row">
          <div class="label">{{ row.label }}</div>
          <div class="bar">
            <div class="fill" :class="{ full: usage(row.kind as any).full }"
                 :style="{ width: usage(row.kind as any).limit < 0 ? '0%' : usage(row.kind as any).pct + '%' }"></div>
          </div>
          <div class="num">{{ fmtLimit(usage(row.kind as any).used, usage(row.kind as any).limit) }}</div>
        </div>
      </div>
    </section>

    <h2>選擇方案</h2>
    <div class="plans">
      <div v-for="p in PLANS" :key="p.key"
           class="plan-card"
           :class="{ current: status?.plan === p.key }">
        <h3>{{ p.name }}</h3>
        <div class="price">{{ p.price }}</div>
        <ul>
          <li v-for="h in p.highlights" :key="h">{{ h }}</li>
        </ul>
        <button v-if="status?.plan === p.key" disabled>目前方案</button>
        <a v-else href="mailto:winsonboy23@gmail.com?subject=升級方案" class="btn">聯絡業務升級</a>
      </div>
    </div>

    <p class="muted small note">
      v1 階段升級 / 降級採人工處理,聯絡上方 email 後我們會在 24 小時內幫你切換並開通對應功能。
      未來接綠界定期定額後可線上自助。
    </p>
  </div>
</template>

<style scoped>
.card { background: #fff; padding: 1rem 1.25rem; border: 1px solid #eee; border-radius: 8px; margin-bottom: 1rem; }
.card h3 { font-size: 0.95rem; margin: 1rem 0 0.5rem; }
.cur { display: flex; gap: 2rem; flex-wrap: wrap; margin-bottom: 0.7rem; }
.plan-name { font-size: 1.2rem; font-weight: 600; }
.muted { color: #888; }
.small { font-size: 0.82rem; }
.badge { display: inline-block; padding: 0.05rem 0.45rem; border-radius: 4px; font-size: 0.7rem; margin-left: 0.4rem; vertical-align: middle; }
.st-trialing { background: #fff5e6; color: #b35900; }
.st-active   { background: #e8f5e9; color: #1b5e20; }
.st-past_due { background: #fce4ec; color: #880e4f; }
.usage { display: flex; flex-direction: column; gap: 0.45rem; }
.usage-row { display: grid; grid-template-columns: 110px 1fr 130px; gap: 0.7rem; align-items: center; font-size: 0.9rem; }
.bar { height: 8px; background: #eee; border-radius: 4px; overflow: hidden; }
.fill { height: 100%; background: #4caf50; transition: width 0.2s; }
.fill.full { background: #c0392b; }
.num { text-align: right; color: #555; }

.plans { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1rem; }
.plan-card {
  background: #fff; border: 1px solid #eee; border-radius: 8px;
  padding: 1.2rem; display: flex; flex-direction: column; gap: 0.6rem;
}
.plan-card.current { border-color: #1a1a1a; box-shadow: 0 0 0 1px #1a1a1a; }
.plan-card h3 { margin: 0; font-size: 1.1rem; }
.plan-card .price { font-size: 1.3rem; font-weight: 600; color: #1a1a1a; }
.plan-card ul { padding-left: 1.1rem; margin: 0.3rem 0; color: #555; font-size: 0.88rem; line-height: 1.6; }
.plan-card button, .plan-card .btn {
  margin-top: auto; padding: 0.55rem;
  border-radius: 4px; border: 1px solid #2b2b2b;
  background: #f5b945; color: #1a1a1a;
  text-align: center; text-decoration: none;
  font-size: 0.9rem; cursor: pointer;
}
.plan-card button:disabled { opacity: 0.5; cursor: not-allowed; }
.note { margin-top: 1rem; }
</style>
