-- 2026-10-24: השבתת נהג (במקום מחיקה), מחיקה רכה של נסיעות, תזכורת ליומן, כתובות שמורות.

-- ===== מחיקה רכה של נסיעות: נעלמת מכל המסכים והסיכומים, אבל נשמרת בשרת =====
alter table public.trips add column if not exists deleted_at timestamptz;

create or replace function public.delete_trip(p_trip uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_t trips;
begin
  select * into v_t from trips where id = p_trip for update;
  if not found then raise exception 'הנסיעה לא קיימת'; end if;
  if not is_fleet_owner(v_t.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_t.status in ('active','offered') then raise exception 'אי אפשר למחוק נסיעה שעדיין פעילה'; end if;
  update trips set deleted_at = now() where id = p_trip;
end $$;
revoke all on function public.delete_trip(uuid) from public, anon;
grant execute on function public.delete_trip(uuid) to authenticated;

-- סיכומים: בלי נסיעות שנמחקו
create or replace function public.trip_stats(p_fleet uuid, p_driver uuid default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  with t as (
    select to_char(done_at at time zone 'Asia/Jerusalem', 'YYYY-MM') ym,
           coalesce(collected_amount, 0) amt
    from trips
    where fleet_id = p_fleet and status = 'done' and done_at is not null and deleted_at is null
      and (p_driver is null or driver_id = p_driver)
  )
  select jsonb_build_object(
    'count', (select count(*) from t),
    'sum',   (select coalesce(sum(amt), 0) from t),
    'months', coalesce((select jsonb_agg(jsonb_build_object('ym', ym, 'n', n, 's', s) order by ym desc)
                        from (select ym, count(*) n, sum(amt) s from t group by ym) m), '[]'::jsonb)
  );
$$;

-- ===== השבתת נהג: ההיסטוריה נשמרת, הוא לא מקבל נסיעות ולא יכול לפעול =====
create or replace function public.set_driver_active(p_driver uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_d drivers;
begin
  select * into v_d from drivers where id = p_driver for update;
  if not found then raise exception 'הנהג לא קיים'; end if;
  if not is_fleet_owner(v_d.fleet_id) then raise exception 'לא מורשה'; end if;
  if not p_active and v_d.status = 'busy' then raise exception 'לנהג יש נסיעה פעילה — אפשר להשבית רק אחרי שיסיים'; end if;
  update drivers set active = p_active, status = case when p_active then status else 'off' end where id = p_driver;
  if not p_active then
    delete from push_tokens where user_id = v_d.user_id;   -- לא מקבל יותר התראות
  end if;
end $$;
revoke all on function public.set_driver_active(uuid, boolean) from public, anon;
grant execute on function public.set_driver_active(uuid, boolean) to authenticated;

-- נהג מושבת לא יכול לקחת או לדחות נסיעות
create or replace function public.accept_offer(p_offer uuid)
returns trips language plpgsql security definer set search_path = public as $$
declare v_o offers; v_drv drivers; v_trip trips;
begin
  select * into v_o from offers where id = p_offer for update;
  if not found then raise exception 'ההצעה לא קיימת'; end if;
  select * into v_drv from drivers where fleet_id = v_o.fleet_id and user_id = auth.uid() and active;
  if not found then raise exception 'לא מורשה'; end if;
  if v_o.status <> 'pending' then raise exception 'הנסיעה כבר נלקחה'; end if;
  if v_o.expires_at <= now() then raise exception 'פג תוקף ההצעה'; end if;
  if v_o.target <> 'bid' and v_o.target <> v_drv.id::text then raise exception 'ההצעה לא מיועדת לך'; end if;
  if v_drv.status = 'busy' then raise exception 'סיים קודם את הנסיעה הנוכחית'; end if;

  update offers set status = 'accepted', accepted_by = v_drv.id where id = p_offer;
  update trips  set driver_id = v_drv.id, status = 'active', accepted_at = now()
    where id = v_o.trip_id returning * into v_trip;
  update drivers set status = 'busy' where id = v_drv.id;
  delete from journal_entries where offer_id = p_offer;

  insert into messages (fleet_id, driver_id, from_role, type, body)
  values (v_o.fleet_id, v_drv.id, 'system', 'system',
          v_drv.name || ' אישר את הנסיעה ' || v_trip.from_text || ' ← ' || v_trip.to_text);
  return v_trip;
end $$;

-- ===== תזכורת חצי שעה לפני נסיעה ביומן הפרטי =====
create or replace function public.journal_reminders()
returns void language plpgsql security definer set search_path = public as $$
declare r record; v_min int;
begin
  for r in
    select j.id, j.title, j.amount, j.pay_method, f.owner_id,
           (j.entry_date + j.entry_time) at time zone 'Asia/Jerusalem' as at
    from journal_entries j join fleets f on f.id = j.fleet_id
    where j.status = 'planned' and not coalesce(j.notified, false)
      and (j.entry_date + j.entry_time) at time zone 'Asia/Jerusalem' between now() and now() + interval '30 minutes'
  loop
    v_min := greatest(1, round(extract(epoch from (r.at - now())) / 60));
    perform push_to(array[r.owner_id], '⏰ בעוד ' || v_min || ' דקות: נסיעה מהיומן',
      r.title || coalesce(' · ₪' || trim_scale(r.amount), '') || coalesce(' (' || r.pay_method || ')', ''), 'journal');
    update journal_entries set notified = true where id = r.id;
  end loop;
end $$;
revoke all on function public.journal_reminders() from public, anon, authenticated;

select cron.unschedule('journal-reminders') where exists (select 1 from cron.job where jobname = 'journal-reminders');
select cron.schedule('journal-reminders', '* * * * *', 'select public.journal_reminders()');

-- ===== כתובות שמורות: המקומות שהכי חוזרים בצי (רק למנהל) =====
create or replace function public.recent_places(p_fleet uuid)
returns table(place text) language sql stable security invoker set search_path = public as $$
  select place from (
    select trim(from_text) place from trips where fleet_id = p_fleet and deleted_at is null
    union all select trim(to_text) from trips where fleet_id = p_fleet and deleted_at is null
    union all select trim(from_text) from journal_entries where fleet_id = p_fleet
    union all select trim(to_text) from journal_entries where fleet_id = p_fleet
  ) x
  where place is not null and length(place) > 1 and place not like 'בדיקת היסטוריה%'
  group by place order by count(*) desc, place limit 100;
$$;
revoke all on function public.recent_places(uuid) from public, anon;
grant execute on function public.recent_places(uuid) to authenticated;
