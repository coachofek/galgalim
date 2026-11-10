-- 2026-11-10: נהג שסימן "לא יכול" על הצעה ישירה — הנסיעה לא נעלמת.
-- היא חוזרת למנהל לרשימת "נסיעות שחזרו אליך לשיבוץ מחדש" (status = 'released').
-- אם ההצעה נשלחה מהיומן — הרשומה ביומן חוזרת ל"מתוכנן" כמו קודם (בלי כפילות ברשימה).

create or replace function public.decline_offer(p_offer uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_o offers; v_drv drivers; v_left int; v_t trips; v_journal int;
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
    update journal_entries set status = 'planned', offer_id = null where offer_id = p_offer;
    get diagnostics v_journal = row_count;
    if v_journal > 0 then
      update trips set status = 'cancelled' where id = v_o.trip_id;
    else
      update trips set status = 'released', driver_id = null where id = v_o.trip_id;
    end if;
    perform push_to(array[(select owner_id from fleets where id = v_o.fleet_id)],
      '❌ ' || v_drv.name || ' לא יכול',
      v_t.from_text || ' ← ' || v_t.to_text || ' · הנסיעה חזרה אליך לשיבוץ', 'declined');
  end if;
end $$;
