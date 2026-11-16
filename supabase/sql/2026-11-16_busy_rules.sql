-- 2026-11-16: בקשות של המנהל
-- 1. נהג אף פעם לא עובר ל"פנוי" לבד — רק כשהוא עצמו לוחץ "חזור למצב פנוי".
--    בסיום נסיעה / שחרור מאושר הנהג עובר ל"עסוק" (status = 'off').
-- 2. המנהל יכול להעביר נהג פנוי ל"עסוק" (set_driver_off).

create or replace function public.finish_trip(p_trip uuid, p_collected numeric, p_pay text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_t trips; v_drv uuid;
begin
  select * into v_t from trips where id = p_trip for update;
  select id into v_drv from drivers where fleet_id = v_t.fleet_id and user_id = auth.uid();
  if v_t.driver_id is distinct from v_drv then raise exception 'לא מורשה'; end if;
  if v_t.status <> 'active' then raise exception 'הנסיעה אינה פעילה'; end if;

  update trips set status = 'done', collected_amount = p_collected, pay_method = p_pay,
                   done_at = now(), note = coalesce(p_note, note)
   where id = p_trip;
  update drivers set status = 'off' where id = v_drv;
end $$;

create or replace function public.decide_release(p_release uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_r releases; v_t trips;
begin
  select * into v_r from releases where id = p_release for update;
  if not is_fleet_owner(v_r.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_r.status not in ('pending','seen') then raise exception 'הבקשה כבר טופלה'; end if;
  select * into v_t from trips where id = v_r.trip_id;

  if p_approve then
    update releases set status = 'approved', decided_at = now() where id = p_release;
    update trips   set status = 'released', driver_id = null where id = v_r.trip_id;
    update drivers set status = 'off' where id = v_r.driver_id and status = 'busy';
    insert into messages (fleet_id, driver_id, from_role, type, body)
    values (v_r.fleet_id, v_r.driver_id, 'owner', 'pm',
            '✅ בקשת השחרור אושרה. הנסיעה הוסרה ממך ואתה במצב עסוק — לחץ "חזור למצב פנוי" כשאתה זמין.');
  else
    update releases set status = 'rejected', decided_at = now() where id = p_release;
    insert into messages (fleet_id, driver_id, from_role, type, body)
    values (v_r.fleet_id, v_r.driver_id, 'owner', 'pm',
            '❌ בקשת השחרור נדחתה. הנסיעה "' || v_t.from_text || ' ← ' || v_t.to_text ||
            '" עדיין באחריותך.');
  end if;
end $$;

create or replace function public.set_driver_off(p_driver uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_d drivers;
begin
  select * into v_d from drivers where id = p_driver for update;
  if not found then raise exception 'הנהג לא קיים'; end if;
  if not is_fleet_owner(v_d.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_d.status = 'busy' then raise exception 'הנהג באמצע נסיעה — בסיום הנסיעה הוא יעבור לעסוק אוטומטית'; end if;
  update drivers set status = 'off' where id = p_driver;
end $$;
revoke all on function public.set_driver_off(uuid) from public, anon;
grant execute on function public.set_driver_off(uuid) to authenticated;
