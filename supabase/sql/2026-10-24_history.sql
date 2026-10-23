-- 2026-10-24: סיכומי היסטוריה מחושבים בשרת — מדויקים בלי קשר לכמות הנסיעות.
-- security invoker: הרשאות הקריאה (RLS) חלות — נהג רואה רק את הנסיעות שלו.
create or replace function public.trip_stats(p_fleet uuid, p_driver uuid default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  with t as (
    select to_char(done_at at time zone 'Asia/Jerusalem', 'YYYY-MM') ym,
           coalesce(collected_amount, 0) amt, coalesce(nullif(pay_method, ''), 'לא צוין') pay
    from trips
    where fleet_id = p_fleet and status = 'done' and done_at is not null
      and (p_driver is null or driver_id = p_driver)
  )
  select jsonb_build_object(
    'count', (select count(*) from t),
    'sum',   (select coalesce(sum(amt), 0) from t),
    'months', coalesce((select jsonb_agg(jsonb_build_object('ym', ym, 'n', n, 's', s) order by ym desc)
                        from (select ym, count(*) n, sum(amt) s from t group by ym) m), '[]'::jsonb)
  );
$$;
revoke all on function public.trip_stats(uuid, uuid) from public, anon;
grant execute on function public.trip_stats(uuid, uuid) to authenticated;

-- אינדקס לשליפת חודש מהירה גם כשיש עשרות אלפי נסיעות
create index if not exists trips_fleet_done_idx on public.trips (fleet_id, done_at) where status = 'done';
create index if not exists trips_driver_done_idx on public.trips (driver_id, done_at) where status = 'done';
