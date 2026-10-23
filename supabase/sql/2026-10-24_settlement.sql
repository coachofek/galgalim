-- 2026-10-24: התחשבנות חודשית עם הנהגים.
-- עמלה = אחוז (ברירת מחדל 10%) מכל מה שהנהג גבה בפועל בחודש.
-- "פתק" = הנוסע משלם למנהל, ולכן הכסף אצל המנהל; כל השאר — הכסף אצל הנהג.
-- שורה תחתונה (net) = עמלה − פתקים:  חיובי → הנהג מעביר למנהל;  שלילי → המנהל מעביר לנהג.

alter table public.fleets add column if not exists commission_pct numeric not null default 10;

create or replace function public.month_settlement(p_fleet uuid, p_ym text, p_driver uuid default null)
returns table(driver_id uuid, name text, code text, phone text, trips bigint, total numeric,
              note_total numeric, commission numeric, net numeric, pct numeric, by_pay jsonb)
language plpgsql stable security definer set search_path = public as $$
declare v_pct numeric; v_from timestamptz; v_to timestamptz;
begin
  select commission_pct into v_pct from fleets where id = p_fleet;
  if not found then raise exception 'הצי לא קיים'; end if;
  -- מנהל רואה את כולם; נהג — רק את עצמו
  if not is_fleet_owner(p_fleet) then
    p_driver := my_driver_id(p_fleet);
    if p_driver is null then raise exception 'לא מורשה'; end if;
  end if;
  v_from := (p_ym || '-01')::timestamp at time zone 'Asia/Jerusalem';
  v_to   := ((p_ym || '-01')::timestamp + interval '1 month') at time zone 'Asia/Jerusalem';

  return query
  with t as (
    select tr.driver_id did, coalesce(tr.collected_amount, 0) amt, coalesce(nullif(tr.pay_method, ''), 'לא צוין') pay
    from trips tr
    where tr.fleet_id = p_fleet and tr.status = 'done' and tr.deleted_at is null and tr.driver_id is not null
      and tr.done_at >= v_from and tr.done_at < v_to
      and (p_driver is null or tr.driver_id = p_driver)
  ), agg as (
    select did, count(*) n, sum(amt) tot, coalesce(sum(amt) filter (where pay = 'פתק'), 0) notes
    from t group by did
  )
  select d.id, d.name, d.code, d.phone, a.n, a.tot, a.notes,
         round(a.tot * v_pct / 100, 2),
         round(a.tot * v_pct / 100, 2) - a.notes,
         v_pct,
         (select jsonb_object_agg(pay, s) from (select pay, sum(amt) s from t where did = d.id group by pay) z)
  from agg a join drivers d on d.id = a.did
  order by a.tot desc;
end $$;
revoke all on function public.month_settlement(uuid, text, uuid) from public, anon;
grant execute on function public.month_settlement(uuid, text, uuid) to authenticated;
