-- 2026-11-16: המנהל מבקש מיקום מנהג שלא שידר — נשלחת לנהג התראה.
-- פתיחת האפליקציה מההתראה מפעילה מחדש את מעקב המיקום (עובד גם בגרסאות ישנות של האפליקציה).

create or replace function public.request_location(p_driver uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_d drivers;
begin
  select * into v_d from drivers where id = p_driver;
  if not found then raise exception 'הנהג לא קיים'; end if;
  if not is_fleet_owner(v_d.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_d.user_id is null then raise exception 'הנהג עדיין לא חיבר את החשבון שלו'; end if;
  perform public.push_to(array[v_d.user_id], '📍 המנהל מבקש את המיקום שלך',
                         'לחץ כאן לפתיחת האפליקציה — המיקום יתעדכן אוטומטית', 'msg');
end $$;
revoke all on function public.request_location(uuid) from public, anon;
grant execute on function public.request_location(uuid) to authenticated;
