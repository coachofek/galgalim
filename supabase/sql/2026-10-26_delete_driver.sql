-- 2026-10-26: מחיקת נהג — שתי אפשרויות:
--   p_with_history = false → הנהג נעלם מכל הרשימות והחשבון שלו מנותק, אבל הנסיעות שלו
--                            נשארות עם השם שלו ונספרות בדוחות ובהתחשבנות.
--   p_with_history = true  → מחיקה לצמיתות של הנהג + כל הנסיעות וההודעות שלו.

alter table public.drivers add column if not exists deleted_at timestamptz;

create or replace function public.delete_driver(p_driver uuid, p_with_history boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_d drivers;
begin
  select * into v_d from drivers where id = p_driver for update;
  if not found then raise exception 'הנהג לא קיים'; end if;
  if not is_fleet_owner(v_d.fleet_id) then raise exception 'לא מורשה'; end if;
  if exists (select 1 from trips where driver_id = p_driver and status = 'active' and deleted_at is null)
    then raise exception 'לנהג יש נסיעה פעילה — אפשר למחוק רק אחרי שיסיים'; end if;

  -- הצעות שממתינות לו — מבטלים
  update trips set status = 'cancelled'
   where id in (select trip_id from offers where target = p_driver::text and status = 'pending');
  update journal_entries set status = 'planned', offer_id = null
   where offer_id in (select id from offers where target = p_driver::text and status = 'pending');
  update offers set status = 'cancelled' where target = p_driver::text and status = 'pending';

  -- לא מקבל יותר התראות
  if v_d.user_id is not null then delete from push_tokens where user_id = v_d.user_id; end if;

  if p_with_history then
    delete from trips where driver_id = p_driver;      -- כולל הצעות ובקשות שחרור שלהן
    delete from offers where target = p_driver::text;
    delete from drivers where id = p_driver;            -- כולל הודעות, סירובים, בקשות שחרור
  else
    update drivers set deleted_at = now(), active = false, status = 'off',
                       user_id = null, join_pin = null
     where id = p_driver;
  end if;
end $$;
revoke all on function public.delete_driver(uuid, boolean) from public, anon;
grant execute on function public.delete_driver(uuid, boolean) to authenticated;
