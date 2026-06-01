-- =============================================================
-- 0012 — Fix tenant_report (0011 漏掉 join bookings)
-- =============================================================
-- 原版的 member_visits CTE 直接寫 b.id / b.start_at 但 FROM 只有 members m,
-- 沒 join bookings → "missing FROM-clause entry for table b"
-- 補上 LEFT JOIN bookings。
-- =============================================================

create or replace function public.tenant_report(
  p_tenant_id uuid,
  p_days      int default 30
) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text;
  v_since timestamptz;
  v_result json;
begin
  select timezone into v_tz from tenants where id = p_tenant_id;
  v_since := (now() at time zone v_tz)::date - (p_days - 1);
  v_since := v_since at time zone v_tz;

  with done as (
    select b.*,
           coalesce(b.actual_amount,
                    sv.price + coalesce((
                      select sum(adn.price) from services adn
                      where adn.id = any (b.addon_ids)
                    ), 0)
           ) as effective_amount
    from bookings b
    join services sv on sv.id = b.service_id
    where b.tenant_id = p_tenant_id
      and b.start_at >= v_since
      and b.status = 'completed'
  ),
  all_bookings as (
    select * from bookings
    where tenant_id = p_tenant_id and start_at >= v_since
  ),
  per_staff as (
    select s.id, s.name,
           count(d.id) as completed,
           coalesce(sum(d.effective_amount), 0) as revenue
    from staff s
    left join done d on d.staff_id = s.id
    where s.tenant_id = p_tenant_id
    group by s.id, s.name
    order by revenue desc
  ),
  per_service as (
    select sv.id, sv.name,
           count(d.id) as completed,
           coalesce(sum(d.effective_amount), 0) as revenue
    from services sv
    left join done d on d.service_id = sv.id
    where sv.tenant_id = p_tenant_id and sv.is_addon = false
    group by sv.id, sv.name
    order by revenue desc
  ),
  -- ★ 修正: 加 LEFT JOIN bookings 才有 b 可用
  member_visits as (
    select m.id,
           count(distinct b.id) filter (
             where b.start_at >= v_since and b.status <> 'cancelled'
           ) as visits_in_range,
           count(distinct b.id) filter (
             where b.start_at < v_since and b.status <> 'cancelled'
           ) as visits_before
    from members m
    left join bookings b on b.member_id = m.id
    where m.tenant_id = p_tenant_id
    group by m.id
  )
  select json_build_object(
    'range_days', p_days,
    'since', v_since,
    'revenue', (select coalesce(sum(effective_amount), 0) from done),
    'bookings_total', (select count(*) from all_bookings),
    'bookings_by_status', (
      select json_object_agg(status, n) from (
        select status, count(*) as n from all_bookings group by status
      ) t
    ),
    'staff', (select coalesce(json_agg(row_to_json(p)), '[]'::json) from per_staff p),
    'services', (select coalesce(json_agg(row_to_json(p)), '[]'::json) from per_service p),
    'new_customers', (
      select count(*) from member_visits
      where visits_in_range > 0 and visits_before = 0
    ),
    'returning_customers', (
      select count(*) from member_visits
      where visits_in_range > 0 and visits_before > 0
    )
  ) into v_result;
  return v_result;
end $$;

grant execute on function public.tenant_report(uuid, int) to authenticated;
