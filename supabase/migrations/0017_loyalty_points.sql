-- =============================================================
-- 0017 — 集點卡 / 點數系統
-- =============================================================
-- 設計:
--   tenants.points_earn_per_dollar — 每 $1 賺多少點 (例 0.1 = $10 一點)
--   tenants.points_redeem_value    — 1 點 = $X 折抵 (預設 1)
--   members.points_balance         — 餘額 denormalized
--   loyalty_transactions           — 異動歷史 (正=賺、負=用)
--
-- 賺點時機: 預約 status=completed 且 actual_amount 不為 null
--   → 呼叫 award_loyalty_points(booking_id)
--   → 看 booking 是否已有 'earned_from_booking' 紀錄 (防重)
--   → 算 floor(amount * earn_rate) 加進 balance
--
-- 兌點: v2 做 (在 /book 加「用點數折抵」入口)
-- =============================================================

alter table public.tenants
  add column points_earn_per_dollar numeric(10,4) not null default 0,
  add column points_redeem_value    numeric(10,2) not null default 1;

alter table public.members
  add column points_balance int not null default 0;

create table public.loyalty_transactions (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  member_id     uuid not null references public.members(id) on delete cascade,
  points        int not null,            -- 正=賺、負=用
  balance_after int not null,
  source        text not null check (source in ('earned_from_booking','redeemed','manual_adjust','expired')),
  booking_id    uuid references public.bookings(id) on delete set null,
  note          text,
  created_at    timestamptz not null default now()
);

create index on public.loyalty_transactions(member_id, created_at desc);
create index on public.loyalty_transactions(tenant_id, created_at desc);
create unique index loyalty_one_earn_per_booking on public.loyalty_transactions(booking_id)
  where source = 'earned_from_booking' and booking_id is not null;

alter table public.loyalty_transactions enable row level security;

create policy tenant_isolation on public.loyalty_transactions
  for all to authenticated
  using (tenant_id in (select public.current_tenant_ids()))
  with check (tenant_id in (select public.current_tenant_ids()));

-- 客人讀自己的異動
create policy own_transactions_read on public.loyalty_transactions
  for select to authenticated
  using (member_id in (select id from members where user_id = auth.uid()));

grant select, insert, update, delete on public.loyalty_transactions to authenticated;
grant select, insert, update, delete on public.loyalty_transactions to service_role;

-- =============================================================
-- award_loyalty_points — 預約完成自動加點
-- 給後台老闆呼叫 (authenticated); 也可 service_role
-- =============================================================
create or replace function public.award_loyalty_points(
  p_booking_id uuid
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_b record;
  v_rate numeric;
  v_points int;
  v_balance int;
begin
  select b.id, b.tenant_id, b.member_id, b.status, b.actual_amount,
         t.points_earn_per_dollar
    into v_b
  from bookings b
  join tenants t on t.id = b.tenant_id
  where b.id = p_booking_id;

  if v_b.id is null then
    raise exception 'booking_not_found' using errcode = 'no_data_found';
  end if;
  if v_b.status <> 'completed' then
    raise exception 'booking_not_completed' using errcode = 'check_violation';
  end if;
  if v_b.actual_amount is null then return 0; end if;
  v_rate := coalesce(v_b.points_earn_per_dollar, 0);
  if v_rate <= 0 then return 0; end if;

  -- idempotent
  if exists (
    select 1 from loyalty_transactions
    where booking_id = p_booking_id and source = 'earned_from_booking'
  ) then
    return 0;
  end if;

  v_points := floor(v_b.actual_amount * v_rate)::int;
  if v_points <= 0 then return 0; end if;

  update members
    set points_balance = points_balance + v_points
    where id = v_b.member_id
    returning points_balance into v_balance;

  insert into loyalty_transactions (tenant_id, member_id, points, balance_after, source, booking_id)
  values (v_b.tenant_id, v_b.member_id, v_points, v_balance, 'earned_from_booking', p_booking_id);

  return v_points;
end $$;

grant execute on function public.award_loyalty_points(uuid) to authenticated;

-- =============================================================
-- adjust_member_points — 老闆手動調整 (送點 / 扣點)
-- =============================================================
create or replace function public.adjust_member_points(
  p_member_id uuid,
  p_points    int,         -- 可正可負
  p_note      text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_tenant uuid;
  v_balance int;
begin
  if p_points = 0 then return 0; end if;

  select tenant_id into v_tenant from members where id = p_member_id;
  if v_tenant is null then
    raise exception 'member_not_found' using errcode = 'no_data_found';
  end if;
  if not exists (
    select 1 from tenant_members where tenant_id = v_tenant and user_id = auth.uid()
  ) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;

  update members
    set points_balance = greatest(0, points_balance + p_points)
    where id = p_member_id
    returning points_balance into v_balance;

  insert into loyalty_transactions (tenant_id, member_id, points, balance_after, source, note)
  values (v_tenant, p_member_id, p_points, v_balance, 'manual_adjust', p_note);

  return v_balance;
end $$;

grant execute on function public.adjust_member_points(uuid, int, text) to authenticated;
