-- 2026-11-16: המנהל שולט בסטטוס הנהג
--   set_driver_status — מעביר נהג (שאינו בנסיעה) לעסוק או לפנוי.
--   owner_finish_trip — נהג שכח ללחוץ "סיים נסיעה": המנהל סוגר את הנסיעה במקומו
--                       (נספרת בדוחות ובהתחשבנות) ובוחר אם הנהג עובר לעסוק או לפנוי.

create or replace function public.set_driver_status(p_driver uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_d drivers;
begin
  if p_status not in ('free','off') then raise exception 'סטטוס לא חוקי'; end if;
  select * into v_d from drivers where id = p_driver for update;
  if not found then raise exception 'הנהג לא קיים'; end if;
  if not is_fleet_owner(v_d.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_d.status = 'busy' then raise exception 'הנהג באמצע נסיעה — קודם סיים את הנסיעה במקומו'; end if;
  update drivers set status = p_status where id = p_driver;
end $$;
revoke all on function public.set_driver_status(uuid, text) from public, anon;
grant execute on function public.set_driver_status(uuid, text) to authenticated;

create or replace function public.owner_finish_trip(p_trip uuid, p_collected numeric, p_pay text,
                                                    p_next text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_t trips;
begin
  if p_next not in ('free','off') then raise exception 'סטטוס לא חוקי'; end if;
  select * into v_t from trips where id = p_trip for update;
  if not found then raise exception 'הנסיעה לא קיימת'; end if;
  if not is_fleet_owner(v_t.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_t.status <> 'active' then raise exception 'הנסיעה אינה פעילה'; end if;

  update trips set status = 'done', collected_amount = p_collected, pay_method = p_pay,
                   done_at = now(), note = coalesce(p_note, note)
   where id = p_trip;
  -- בקשת שחרור פתוחה על הנסיעה כבר לא רלוונטית
  update releases set status = 'rejected', decided_at = now()
   where trip_id = p_trip and status in ('pending','seen');
  update drivers set status = p_next where id = v_t.driver_id and status = 'busy';
  insert into messages (fleet_id, driver_id, from_role, type, body)
  values (v_t.fleet_id, v_t.driver_id, 'owner', 'pm',
          '🏁 המנהל סגר את הנסיעה "' || v_t.from_text || ' ← ' || v_t.to_text || '" במקומך. עכשיו אתה במצב ' ||
          case when p_next = 'free' then 'פנוי' else 'עסוק' end || '.');
end $$;
revoke all on function public.owner_finish_trip(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.owner_finish_trip(uuid, numeric, text, text, text) to authenticated;
