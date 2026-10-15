-- PharmaStock - test suite
-- Prerequisites: migrations 001-003 applied AND supabase/seed.sql loaded.
-- Run (as the database owner, on a LOCAL or throwaway database only):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/run_tests.sql
-- Everything happens inside one transaction that is rolled back at the end,
-- so the database is left untouched. Any failure aborts with "FAIL: ...".
-- NOT YET EXECUTED by the author: expect to fix small errors on the first run.

begin;

create schema test;
grant usage on schema test to public;

create function test.assert(cond boolean, label text) returns void
language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;

-- Passes only if the statement raises an error.
create function test.throws(stmt text, label text) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS: % [%]', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL (no error raised): %', label;
end $$;

create function test.avail(p_med uuid, p_pharm uuid) returns text
language sql stable as $$
  select availability from public_availability(p_med, null) where pharmacy_id = p_pharm
$$;

-- Test users: manager A, staff A, manager B, manager C, platform admin, newcomer (no profile).
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'manager.a@test.invalid'),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'staff.a@test.invalid'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'manager.b@test.invalid'),
  ('cccccccc-0000-4000-8000-000000000001', 'manager.c@test.invalid'),
  ('dddddddd-0000-4000-8000-000000000001', 'admin@test.invalid'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'newcomer@test.invalid');

insert into profiles (id, full_name, role, pharmacy_id) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'Gérant A',  'manager', '20000000-0000-4000-8000-00000000000a'),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'Employé A', 'staff',   '20000000-0000-4000-8000-00000000000a'),
  ('bbbbbbbb-0000-4000-8000-000000000001', 'Gérant B',  'manager', '20000000-0000-4000-8000-00000000000b'),
  ('cccccccc-0000-4000-8000-000000000001', 'Gérant C',  'manager', '20000000-0000-4000-8000-00000000000c'),
  ('dddddddd-0000-4000-8000-000000000001', 'Admin',     'admin',   null);

-- Ids that the restricted roles need (they cannot read other pharmacies' rows themselves).
select set_config('test.b_batch', (select id::text from batches where batch_number = 'LT-B1'), true);
select set_config('test.a_batch1', (select id::text from batches where batch_number = 'LT-A1'), true);
select set_config('test.a_batch2', (select id::text from batches where batch_number = 'LT-A2'), true);
select set_config('test.a_batch3', (select id::text from batches where batch_number = 'LT-A3'), true);

-- ===========================================================================
-- TEST GROUP 1 - Public search finds the exact strength and form
-- ===========================================================================
set local role anon;

select test.assert((select count(*) from public_search_medicines('paracetamol')) = 2,
  '1a  la recherche sans accent trouve les 2 dosages de paracétamol');
select test.assert((select count(*) from public_search_medicines('doliprane 500')) = 1
  and (select strength from public_search_medicines('doliprane 500')) = '500 mg',
  '1b  "doliprane 500" ne renvoie que le dosage 500 mg');
select test.assert((select count(*) from public_search_medicines('amoxicilline 250')) = 1
  and (select dosage_form from public_search_medicines('amoxicilline 250')) = 'suspension buvable',
  '1c  amoxicilline 250 mg/5 ml est une forme distincte de la gélule 500 mg');
select test.assert((select count(*) from public_search_medicines('p')) = 0,
  '1d  une requête trop courte ne renvoie rien');
select test.assert((select count(*) from public_search_medicines('paracetamol 500')) = 1,
  '1d2 "paracetamol 500" ne renvoie que le dosage 500 mg');

-- Availability is per exact medicine: 500 mg has 3 pharmacies, 1000 mg has 2.
select test.assert((select count(*) from public_availability('10000000-0000-4000-8000-000000000001')) = 3,
  '1e  paracétamol 500 mg : 3 pharmacies publient');
select test.assert((select count(*) from public_availability('10000000-0000-4000-8000-000000000002')) = 2,
  '1f  paracétamol 1000 mg : 2 pharmacies publient (pas de mélange des dosages)');
select test.assert((select count(*) from public_availability('10000000-0000-4000-8000-000000000001', 'Tokoin')) = 1,
  '1g  le filtre par quartier fonctionne');
select test.assert((select count(*) from public_availability('10000000-0000-4000-8000-000000000001')
                    where eligible_quantity is not null) = 0,
  '1h  aucune quantité exacte n''est publique par défaut');
select test.assert((select count(*) from public_pharmacy_directory()) = 3,
  '1i  l''annuaire public liste les 3 pharmacies de démonstration');

-- Initial statuses from the seed data.
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000a') = 'available',
  '1j  Tokoin / paracétamol 500 mg : DISPONIBLE');
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000b') = 'confirm',
  '1k  Bè / paracétamol 500 mg : CONFIRMER (données de 80 h)');
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000c') = 'unavailable',
  '1l  Agoè / paracétamol 500 mg : INDISPONIBLE (stock à zéro)');
select test.assert(test.avail('10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-00000000000a') = 'unavailable',
  '3a  Tokoin / paracétamol 1000 mg : lot périmé, jamais DISPONIBLE');

-- ===========================================================================
-- TEST GROUP 2 - Public visitors cannot modify (or even read) private data
-- ===========================================================================
select test.throws($q$ select * from batches $q$,            '2a  anon ne peut pas lire les lots');
select test.throws($q$ select * from pharmacies $q$,         '2b  anon ne peut pas lire les pharmacies');
select test.throws($q$ select * from stock_movements $q$,    '2c  anon ne peut pas lire les mouvements');
select test.throws($q$ select * from suppliers $q$,          '2d  anon ne peut pas lire les fournisseurs');
select test.throws($q$ update batches set quantity_on_hand = 9999 $q$, '2e  anon ne peut pas modifier un stock');
select test.throws($q$ insert into stock_movements (pharmacy_id, medicine_id, batch_id, movement_type, quantity_delta, balance_after)
                       values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'receipt', 1, 1) $q$,
                   '2f  anon ne peut pas écrire dans le registre');
select test.throws($q$ select receive_stock('10000000-0000-4000-8000-000000000001', 'X', current_date + 10, 5) $q$,
                   '2g  anon ne peut pas appeler receive_stock');
select test.throws($q$ select _apply_movement(gen_random_uuid(), gen_random_uuid(), 'receipt', 5, null, null, null) $q$,
                   '2h  le moteur interne n''est appelable par personne');

reset role;

-- ===========================================================================
-- TEST GROUP 3 - Pharmacy A: isolation, stock changes, expiry
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
set local role authenticated;

-- 5. Pharmacy A cannot see or touch pharmacy B
select test.assert((select count(*) from pharmacies) = 1, '5a  A ne voit que sa propre pharmacie');
select test.assert((select count(*) from batches) = 5, '5b  A ne voit que ses 5 lots');
select test.assert((select count(*) from batches where pharmacy_id = '20000000-0000-4000-8000-00000000000b') = 0,
  '5c  A ne voit aucun lot de B');
select test.assert((select count(*) from stock_movements where pharmacy_id = '20000000-0000-4000-8000-00000000000b') = 0,
  '5d  A ne voit aucun mouvement de B');
select test.assert((select count(*) from suppliers where pharmacy_id = '20000000-0000-4000-8000-00000000000b') = 0,
  '5e  A ne voit aucun fournisseur de B');
select test.throws($q$ select record_stock_movement(current_setting('test.b_batch')::uuid, 'dispense', 1) $q$,
  '5f  A ne peut pas modifier un lot de B');
select test.throws($q$ insert into suppliers (pharmacy_id, name) values ('20000000-0000-4000-8000-00000000000b', 'Intrus') $q$,
  '5g  A ne peut pas créer de fournisseur chez B');
select test.throws($q$ update pharmacies set status = 'verified' $q$,
  '5h  A ne peut pas modifier directement une pharmacie');
select test.throws($q$ insert into batches (pharmacy_id, medicine_id, batch_number, expiry_date)
                       values ('20000000-0000-4000-8000-00000000000a', '10000000-0000-4000-8000-000000000001', 'Z', current_date + 5) $q$,
  '5i  A ne peut pas écrire directement dans les lots');

-- 2. Stock updates change availability (and are validated)
select record_stock_movement(current_setting('test.a_batch1')::uuid, 'dispense', 5, null,
                             'f0000000-0000-4000-8000-000000000001');
select record_stock_movement(current_setting('test.a_batch1')::uuid, 'dispense', 5, null,
                             'f0000000-0000-4000-8000-000000000001');   -- same request id: a retry
select test.assert((select quantity_on_hand from batches where id = current_setting('test.a_batch1')::uuid) = 115,
  '4a  une requête rejouée (même request_id) n''est appliquée qu''une fois');
select test.assert((select count(*) from stock_movements where request_id = 'f0000000-0000-4000-8000-000000000001') = 1,
  '4b  une seule ligne dans le registre pour cette requête');
select test.throws($q$ select record_stock_movement(current_setting('test.a_batch1')::uuid, 'dispense', 1000) $q$,
  '4c  vendre plus que le stock est refusé (pas de solde négatif)');
select test.throws($q$ select record_stock_movement(current_setting('test.a_batch1')::uuid, 'damage', 1) $q$,
  '4d  une casse sans motif est refusée');
select test.throws($q$ select record_stock_movement(current_setting('test.a_batch1')::uuid, 'adjustment', -3, null) $q$,
  '4e  un ajustement sans motif est refusé');

select record_stock_movement(current_setting('test.a_batch1')::uuid, 'dispense', 115);   -- sell everything left
reset role; set local role anon;
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000a') = 'unavailable',
  '2i  tout vendre => la disponibilité publique passe à INDISPONIBLE');
reset role; set local role authenticated;

select receive_stock('10000000-0000-4000-8000-000000000001', 'LT-A9', public.lome_today() + 100, 5,
                     null, 420, gen_random_uuid());
reset role; set local role anon;
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000a') = 'available',
  '2j  une réception de stock => la disponibilité repasse à DISPONIBLE');
reset role; set local role authenticated;

select record_stock_movement(current_setting('test.a_batch1')::uuid, 'adjustment', 10, 'Inventaire physique');

-- 3. Expired stock is never available
select test.throws($q$ select receive_stock('10000000-0000-4000-8000-000000000001', 'LT-OLD', public.lome_today() - 1, 5) $q$,
  '3b  on ne peut pas recevoir un lot déjà périmé');
select test.throws($q$ select record_stock_movement(current_setting('test.a_batch2')::uuid, 'dispense', 1) $q$,
  '3c  on ne peut pas vendre un lot périmé');
select test.throws($q$ select record_stock_movement(current_setting('test.a_batch2')::uuid, 'adjustment', 5, 'test') $q$,
  '3d  on ne peut pas ajouter de stock à un lot périmé');
select record_stock_movement(current_setting('test.a_batch2')::uuid, 'expiry_writeoff', 40, 'Retrait des périmés');
select test.assert((select quantity_on_hand from batches where id = current_setting('test.a_batch2')::uuid) = 0,
  '3e  le retrait des périmés est autorisé et vide le lot');

-- Roles inside a pharmacy: staff can move stock, but cannot publish or manage users.
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000002', true);
select record_stock_movement(current_setting('test.a_batch3')::uuid, 'dispense', 1);
select test.throws($q$ select set_product_listing('10000000-0000-4000-8000-000000000001', true, false, 600) $q$,
  '6a  un employé ne peut pas publier un produit');
select test.throws($q$ select set_pharmacy_listing(false) $q$,
  '6b  un employé ne peut pas changer la publication de la pharmacie');
select test.throws($q$ select assign_member('eeeeeeee-0000-4000-8000-000000000001', 'Intrus', 'staff') $q$,
  '6c  un employé ne peut pas ajouter d''utilisateurs');
reset role;

-- Time passes: A's paracétamol 500 mg still physically exists but its batches expire.
select test.assert((select sum(quantity_on_hand) from batches
                    where pharmacy_id = '20000000-0000-4000-8000-00000000000a'
                      and medicine_id = '10000000-0000-4000-8000-000000000001') = 15,
  '3f  A possède 15 unités physiques de paracétamol 500 mg');
update batches set expiry_date = public.lome_today() - 1
  where pharmacy_id = '20000000-0000-4000-8000-00000000000a'
    and medicine_id = '10000000-0000-4000-8000-000000000001';
set local role anon;
select test.assert(test.avail('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-00000000000a') = 'unavailable',
  '3g  le stock expiré n''est jamais présenté comme disponible');
reset role;

-- ===========================================================================
-- TEST GROUP 4 - Old inventory data becomes "to confirm"
-- ===========================================================================
update pharmacy_products set last_verified_at = now() - interval '49 hours'
  where pharmacy_id = '20000000-0000-4000-8000-00000000000c'
    and medicine_id = '10000000-0000-4000-8000-000000000002';
set local role anon;
select test.assert(test.avail('10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-00000000000c') = 'confirm',
  '4f  des données de plus de 48 h passent à CONFIRMER LA DISPONIBILITÉ');
reset role;

select set_config('request.jwt.claim.sub', 'cccccccc-0000-4000-8000-000000000001', true);
set local role authenticated;
select confirm_availability('10000000-0000-4000-8000-000000000002');
reset role; set local role anon;
select test.assert(test.avail('10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-00000000000c') = 'available',
  '4g  la confirmation du gérant rétablit DISPONIBLE');
reset role;

-- ===========================================================================
-- TEST GROUP 5 - Unverified pharmacies cannot publish
-- ===========================================================================
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000001', true);
set local role authenticated;

select test.throws($q$ select receive_stock('10000000-0000-4000-8000-000000000001', 'X', public.lome_today() + 10, 1) $q$,
  '8a  un compte sans pharmacie ne peut pas gérer de stock');
select test.throws($q$ select register_pharmacy('P', 'Rue', 'Tokoin', '+228 90 00 00 99', 'x@example.invalid',
                       '8h-18h', 'DEMO-9999', 'Gérant', false, 'v1') $q$,
  '8b  l''inscription exige l''acceptation des conditions');
select set_config('test.new_ph',
  register_pharmacy('Pharmacie Test Non Vérifiée', 'Rue Test', 'Tokoin', '+228 90 00 00 99',
                    'test@example.invalid', '8h-18h', 'DEMO-9999', 'Gérant Test', true, 'v1')::text, true);
select test.throws($q$ select set_pharmacy_listing(true) $q$,
  '8c  une pharmacie en attente ne peut pas publier');
select test.throws($q$ update pharmacies set listing_enabled = true $q$,
  '8d  ni en modifiant la table directement');
select test.assert((select count(*) from public_pharmacy_directory() where name like 'Pharmacie Test%') = 0,
  '8e  elle est absente de l''annuaire public');
reset role;

select test.throws($q$ update pharmacies set listing_enabled = true where id = current_setting('test.new_ph')::uuid $q$,
  '8f  même le propriétaire de la base est bloqué par la contrainte');

-- Only a platform admin can verify.
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
set local role authenticated;
select test.throws($q$ select admin_set_pharmacy_status(current_setting('test.new_ph')::uuid, 'verified') $q$,
  '8g  un gérant ne peut pas vérifier une pharmacie');
reset role;

select set_config('request.jwt.claim.sub', 'dddddddd-0000-4000-8000-000000000001', true);
set local role authenticated;
select test.assert((select count(*) from pharmacies) = 4, '6d  l''admin voit toutes les pharmacies');
select test.assert((select count(*) from batches) = 0, '6e  l''admin ne voit aucun stock privé');
select admin_set_pharmacy_status(current_setting('test.new_ph')::uuid, 'verified');
reset role;

select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000001', true);
set local role authenticated;
select set_pharmacy_listing(true);
reset role; set local role anon;
select test.assert((select count(*) from public_pharmacy_directory() where name like 'Pharmacie Test%') = 1,
  '8h  après vérification, la pharmacie peut publier');
reset role;

select set_config('request.jwt.claim.sub', 'dddddddd-0000-4000-8000-000000000001', true);
set local role authenticated;
select admin_set_pharmacy_status(current_setting('test.new_ph')::uuid, 'suspended');
reset role;
select test.assert((select listing_enabled from pharmacies where id = current_setting('test.new_ph')::uuid) = false,
  '8i  la suspension retire automatiquement la publication');

-- ===========================================================================
-- TEST GROUP 6 - Audit trail and ledger integrity
-- ===========================================================================
select test.throws($q$ update stock_movements set quantity_delta = quantity_delta $q$,
  '7a  le registre des mouvements refuse les modifications');
select test.throws($q$ delete from stock_movements $q$,
  '7b  le registre des mouvements refuse les suppressions');
select test.throws($q$ delete from audit_log $q$,
  '7c  le journal d''audit refuse les suppressions');
select test.assert((select count(*) from audit_log where action = 'admin.status') >= 2,
  '7d  les changements de statut sont journalisés');
select test.assert((select count(*) from check_ledger_consistency()) = 0,
  '7e  chaque solde de lot est égal à la somme de son registre');

select 'TOUS LES TESTS ONT RÉUSSI' as resultat;
rollback;
