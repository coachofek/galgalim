-- 2026-10-23: מכרז לכל הנהגים (גם "עסוק"), שליחה חוזרת של מכרז, יומן עם איסוף/יעד/גבייה/תשלום,
-- והתראה עם צפצוף למנהל כשנהג מסיים נסיעה.

-- ===== יומן: שדות מובנים =====
alter table public.journal_entries
  add column if not exists from_text text,
  add column if not exists to_text text,
  add column if not exists amount numeric,
  add column if not exists pay_method text;

-- ===== מכרז: נשלח לכל הנהגים הפעילים שלא נמצאים באמצע נסיעה (פנויים + עסוקים) =====
create or replace function public.send_offer(p_fleet uuid, p_target text, p_from text, p_from_lat double precision,
  p_from_lng double precision, p_to text, p_to_lat double precision, p_to_lng double precision, p_amount numeric,
  p_pay text, p_note text default null, p_source text default 'direct', p_journal uuid default null)
returns offers language plpgsql security definer set search_path = public as $$
declare v_trip uuid; v_offer offers;
begin
  if not is_fleet_owner(p_fleet) then raise exception 'לא מורשה'; end if;

  insert into trips (fleet_id, from_text, from_lat, from_lng, to_text, to_lat, to_lng,
                     agreed_amount, pay_method, note, source, status)
  values (p_fleet, p_from, p_from_lat, p_from_lng, p_to, p_to_lat, p_to_lng,
          p_amount, p_pay, p_note, p_source, 'offered')
  returning id into v_trip;

  insert into offers (fleet_id, trip_id, target) values (p_fleet, v_trip, p_target)
  returning * into v_offer;

  if p_target = 'bid' then
    insert into messages (fleet_id, driver_id, from_role, type, body)
    select p_fleet, d.id, 'owner', 'bid',
           'מכרז: ' || p_from || ' ← ' || p_to || ' · ₪' || trim_scale(p_amount)
    from drivers d where d.fleet_id = p_fleet and d.active and d.status in ('free','off');
  else
    insert into messages (fleet_id, driver_id, from_role, type, body)
    values (p_fleet, p_target::uuid, 'owner', 'offer',
            'הצעת נסיעה: ' || p_from || ' ← ' || p_to || ' · ₪' || trim_scale(p_amount));
  end if;

  if p_journal is not null then
    update journal_entries set status = 'pending', offer_id = v_offer.id where id = p_journal;
  end if;
  return v_offer;
end $$;

-- ===== אישור: גם נהג במצב "עסוק" יכול לקחת; רק מי שבאמצע נסיעה לא =====
create or replace function public.accept_offer(p_offer uuid)
returns trips language plpgsql security definer set search_path = public as $$
declare v_o offers; v_drv drivers; v_trip trips;
begin
  select * into v_o from offers where id = p_offer for update;   -- נעילה: מונע שני זוכים
  if not found then raise exception 'ההצעה לא קיימת'; end if;

  select * into v_drv from drivers where fleet_id = v_o.fleet_id and user_id = auth.uid();
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

-- ===== דחייה: מכרז נסגר כשכל הנהגים הרלוונטיים דחו — ואז המנהל מקבל התראה =====
create or replace function public.decline_offer(p_offer uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_o offers; v_drv drivers; v_left int; v_t trips;
begin
  select * into v_o from offers where id = p_offer for update;
  if not found or v_o.status <> 'pending' then return; end if;
  select * into v_drv from drivers where fleet_id = v_o.fleet_id and user_id = auth.uid();
  if not found then raise exception 'לא מורשה'; end if;

  insert into offer_declines (offer_id, driver_id) values (p_offer, v_drv.id)
    on conflict do nothing;
  select * into v_t from trips where id = v_o.trip_id;

  if v_o.target = 'bid' then
    select count(*) into v_left from drivers d
     where d.fleet_id = v_o.fleet_id and d.active and d.status in ('free','off')
       and not exists (select 1 from offer_declines x where x.offer_id = p_offer and x.driver_id = d.id);
    if v_left = 0 then
      update offers set status = 'declined' where id = p_offer;
      update trips  set status = 'cancelled' where id = v_o.trip_id;
      update journal_entries set status = 'planned', offer_id = null where offer_id = p_offer;
      perform push_to(array[(select owner_id from fleets where id = v_o.fleet_id)],
        '📣 אף נהג לא לקח את המכרז', v_t.from_text || ' ← ' || v_t.to_text || ' · אפשר לשלוח שוב', 'bid_closed');
    end if;
  else
    update offers set status = 'declined' where id = p_offer;
    update trips  set status = 'cancelled' where id = v_o.trip_id;
    update journal_entries set status = 'planned', offer_id = null where offer_id = p_offer;
    perform push_to(array[(select owner_id from fleets where id = v_o.fleet_id)],
      '❌ ' || v_drv.name || ' לא יכול', v_t.from_text || ' ← ' || v_t.to_text, 'declined');
  end if;
end $$;

-- ===== שליחה חוזרת של מכרז ("נדנוד") =====
-- מכרז פתוח: תזכורת לכל מי שעוד לא לקח. מכרז שנסגר/פג: נפתח מחדש ל-12 שעות.
-- בשני המקרים — גם מי שסימן "לא יכול" מקבל הזדמנות נוספת.
create or replace function public.resend_bid(p_offer uuid)
returns offers language plpgsql security definer set search_path = public as $$
declare v_o offers; v_t trips; v_n int;
begin
  select * into v_o from offers where id = p_offer for update;
  if not found then raise exception 'המכרז לא קיים'; end if;
  if not is_fleet_owner(v_o.fleet_id) then raise exception 'לא מורשה'; end if;
  if v_o.target <> 'bid' then raise exception 'אפשר לשלוח שוב רק מכרז'; end if;
  if v_o.status in ('accepted','cancelled') then raise exception 'המכרז כבר נסגר'; end if;
  select * into v_t from trips where id = v_o.trip_id;
  if v_t.status not in ('offered','cancelled') then raise exception 'הנסיעה כבר לא פתוחה'; end if;

  delete from offer_declines where offer_id = p_offer;
  update offers set status = 'pending', expires_at = greatest(expires_at, now() + interval '12 hours')
   where id = p_offer returning * into v_o;
  update trips set status = 'offered' where id = v_o.trip_id;

  insert into messages (fleet_id, driver_id, from_role, type, body)
  select v_o.fleet_id, d.id, 'owner', 'bid',
         '🔔 תזכורת — מכרז פתוח: ' || v_t.from_text || ' ← ' || v_t.to_text || ' · ₪' || trim_scale(v_t.agreed_amount)
  from drivers d where d.fleet_id = v_o.fleet_id and d.active and d.status in ('free','off');
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'אין כרגע נהגים זמינים (כולם באמצע נסיעה)'; end if;
  return v_o;
end $$;
revoke all on function public.resend_bid(uuid) from public, anon;
grant execute on function public.resend_bid(uuid) to authenticated;

-- ===== נהג סיים נסיעה → התראה עם צפצוף למנהל =====
create or replace function public.trg_push_trip_done() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid; v_name text; v_body text;
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    select owner_id into v_owner from public.fleets where id = new.fleet_id;
    select name into v_name from public.drivers where id = new.driver_id;
    v_body := new.from_text || ' ← ' || new.to_text || ' · נגבה ₪' || trim_scale(coalesce(new.collected_amount, 0))
              || coalesce(' (' || new.pay_method || ')', '')
              || case when new.collected_amount is distinct from new.agreed_amount
                      then ' · סוכם ₪' || trim_scale(new.agreed_amount) else '' end;
    perform public.push_to(array[v_owner], '🏁 ' || coalesce(v_name,'נהג') || ' סיים נסיעה', v_body, 'done');
  end if;
  return null;
end $$;

drop trigger if exists push_on_trip_done on public.trips;
create trigger push_on_trip_done after update of status on public.trips
  for each row execute function public.trg_push_trip_done();
