-- PharmaStock - seed: FICTIONAL DEMONSTRATION DATA
-- Three fictional pharmacies in Lomé. Every pharmacy has is_demo = true and a
-- "[DÉMO]" name prefix, so it can never be confused with a real pharmacy.
-- Phone numbers, e-mails and authorization numbers are invented.
-- Run as the database owner (e.g. `psql`, or automatically by `supabase db reset`).
-- NEVER run this on a production database.

-- ---------------------------------------------------------------------------
-- Pharmacies (all verified and listed so the public search has something to show)
-- ---------------------------------------------------------------------------
insert into pharmacies
  (id, name, address, neighborhood, phone, phone_public, email, opening_hours, authorization_ref,
   status, listing_enabled, is_demo, terms_accepted_at, terms_version, verified_at)
values
  ('20000000-0000-4000-8000-00000000000a', '[DÉMO] Pharmacie Tokoin', 'Rue Démo 12, Tokoin, Lomé', 'Tokoin',
   '+228 90 00 00 01', '+228 90 00 00 01', 'demo-a@example.invalid', 'Lun-Sam 8h-20h', 'DEMO-0001',
   'verified', true, true, now(), 'demo', now()),
  ('20000000-0000-4000-8000-00000000000b', '[DÉMO] Pharmacie Bè', 'Avenue Démo 5, Bè, Lomé', 'Bè',
   '+228 90 00 00 02', '+228 90 00 00 02', 'demo-b@example.invalid', '7j/7 8h-22h', 'DEMO-0002',
   'verified', true, true, now(), 'demo', now()),
  ('20000000-0000-4000-8000-00000000000c', '[DÉMO] Pharmacie Agoè', 'Boulevard Démo 30, Agoè, Lomé', 'Agoè',
   '+228 90 00 00 03', '+228 90 00 00 03', 'demo-c@example.invalid', 'Lun-Sam 8h-19h', 'DEMO-0003',
   'verified', true, true, now(), 'demo', now());

-- ---------------------------------------------------------------------------
-- Approved medicine catalogue. Each strength / dosage form is its own row.
-- ---------------------------------------------------------------------------
insert into medicines (id, generic_name, brand_name, strength, dosage_form, stock_unit, approved) values
  ('10000000-0000-4000-8000-000000000001', 'Paracétamol', 'Doliprane', '500 mg', 'comprimé', 'boîte', true),
  ('10000000-0000-4000-8000-000000000002', 'Paracétamol', 'Doliprane', '1000 mg', 'comprimé', 'boîte', true),
  ('10000000-0000-4000-8000-000000000003', 'Amoxicilline', 'Clamoxyl', '500 mg', 'gélule', 'boîte', true),
  ('10000000-0000-4000-8000-000000000004', 'Amoxicilline', 'Clamoxyl', '250 mg/5 ml', 'suspension buvable', 'flacon', true),
  ('10000000-0000-4000-8000-000000000005', 'Artéméther / Luméfantrine', 'Coartem', '20/120 mg', 'comprimé', 'boîte', true),
  ('10000000-0000-4000-8000-000000000006', 'Ibuprofène', 'Advil', '200 mg', 'comprimé', 'boîte', true),
  ('10000000-0000-4000-8000-000000000007', 'Sels de réhydratation orale', 'SRO', '4,1 g', 'poudre en sachet', 'sachet', true);

insert into suppliers (id, pharmacy_id, name) values
  ('30000000-0000-4000-8000-0000000000a1', '20000000-0000-4000-8000-00000000000a', 'Grossiste Démo 1'),
  ('30000000-0000-4000-8000-0000000000b1', '20000000-0000-4000-8000-00000000000b', 'Grossiste Démo 1'),
  ('30000000-0000-4000-8000-0000000000c1', '20000000-0000-4000-8000-00000000000c', 'Grossiste Démo 1');

-- ---------------------------------------------------------------------------
-- Stock. Every quantity is created through the ledger (_apply_movement), so
-- balances are consistent with the movement history.
-- p_days < 0 creates a batch that is ALREADY EXPIRED (it is created valid, filled,
-- then its date is moved into the past, like time passing in real life).
-- ---------------------------------------------------------------------------
create function pg_temp.seed_batch(
  p_ph uuid, p_med uuid, p_no text, p_qty int, p_days int, p_price int, p_sup uuid)
returns void language plpgsql as $$
declare v_batch uuid;
begin
  insert into pharmacy_products (pharmacy_id, medicine_id, min_stock, public_listing, price_xof)
  values (p_ph, p_med, 20, true, p_price)
  on conflict do nothing;

  insert into batches (pharmacy_id, medicine_id, batch_number, expiry_date, supplier_id, unit_cost_xof)
  values (p_ph, p_med, p_no, public.lome_today() + greatest(p_days, 30), p_sup, (p_price * 0.7)::int)
  returning id into v_batch;

  if p_qty > 0 then
    perform public._apply_movement(p_ph, v_batch, 'receipt', p_qty,
                                   'Stock initial de démonstration', null, null);
  end if;
  if p_days < 30 then
    update batches set expiry_date = public.lome_today() + p_days where id = v_batch;
  end if;
end $$;

do $$
declare
  a uuid := '20000000-0000-4000-8000-00000000000a';
  b uuid := '20000000-0000-4000-8000-00000000000b';
  c uuid := '20000000-0000-4000-8000-00000000000c';
  sa uuid := '30000000-0000-4000-8000-0000000000a1';
  sb uuid := '30000000-0000-4000-8000-0000000000b1';
  sc uuid := '30000000-0000-4000-8000-0000000000c1';
  m1 uuid := '10000000-0000-4000-8000-000000000001';  -- paracétamol 500 mg
  m2 uuid := '10000000-0000-4000-8000-000000000002';  -- paracétamol 1000 mg
  m3 uuid := '10000000-0000-4000-8000-000000000003';  -- amoxicilline 500 mg gélule
  m4 uuid := '10000000-0000-4000-8000-000000000004';  -- amoxicilline 250 mg/5 ml
  m5 uuid := '10000000-0000-4000-8000-000000000005';  -- Coartem
  m6 uuid := '10000000-0000-4000-8000-000000000006';  -- ibuprofène
  m7 uuid := '10000000-0000-4000-8000-000000000007';  -- SRO
begin
  -- Tokoin: fresh data. Paracétamol 1000 mg has ONLY an expired batch (so it is unavailable).
  perform pg_temp.seed_batch(a, m1, 'LT-A1', 120,  300,  600, sa);
  perform pg_temp.seed_batch(a, m2, 'LT-A2',  40,  -20,  900, sa);
  perform pg_temp.seed_batch(a, m3, 'LT-A3',  30,  200, 2500, sa);
  perform pg_temp.seed_batch(a, m5, 'LT-A4',   8,   40, 2200, sa);   -- low stock + expiring soon
  perform pg_temp.seed_batch(a, m6, 'LT-A5',  50,  250, 1200, sa);

  -- Bè: good stock, but its information is 80 h old, so it shows "à confirmer".
  perform pg_temp.seed_batch(b, m1, 'LT-B1',  60,  220,  600, sb);
  perform pg_temp.seed_batch(b, m3, 'LT-B2',  40,  180, 2500, sb);
  perform pg_temp.seed_batch(b, m5, 'LT-B3',  25,  150, 2200, sb);
  perform pg_temp.seed_batch(b, m7, 'LT-B4', 100,  365,  300, sb);

  -- Agoè: paracétamol 500 mg and Coartem are out of stock.
  perform pg_temp.seed_batch(c, m1, 'LT-C1',   0,  200,  600, sc);
  perform pg_temp.seed_batch(c, m2, 'LT-C2',  35,  260,  900, sc);
  perform pg_temp.seed_batch(c, m4, 'LT-C3',  12,   90, 2000, sc);
  perform pg_temp.seed_batch(c, m5, 'LT-C4',   0,  100, 2200, sc);
  perform pg_temp.seed_batch(c, m6, 'LT-C5',  20,  300, 1200, sc);

  update pharmacy_products set last_verified_at = now() - interval '2 hours'  where pharmacy_id = a;
  update pharmacy_products set last_verified_at = now() - interval '80 hours' where pharmacy_id = b;
  update pharmacy_products set last_verified_at = now() - interval '5 hours'  where pharmacy_id = c;
end $$;

-- ---------------------------------------------------------------------------
-- Demo logins (optional). Passwords are never stored in this file.
--  1. Create three users in the Supabase dashboard (Authentication > Users),
--     e.g. manager.a@example.invalid, staff.a@example.invalid, admin@example.invalid.
--  2. Copy their user ids into the statements below and run them.
-- ---------------------------------------------------------------------------
-- insert into profiles (id, full_name, role, pharmacy_id) values
--   ('<uuid of manager.a>', 'Gérant Démo A',   'manager', '20000000-0000-4000-8000-00000000000a'),
--   ('<uuid of staff.a>',   'Employé Démo A',  'staff',   '20000000-0000-4000-8000-00000000000a'),
--   ('<uuid of admin>',     'Admin Plateforme', 'admin',   null);
