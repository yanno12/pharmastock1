-- PharmaStock - 002: functions and views
-- All writes by pharmacies/admins go through these functions. Each one checks
-- the caller's role and pharmacy itself (SECURITY DEFINER + auth.uid()), so
-- permissions are enforced in the database, not in the UI.
-- NOT YET EXECUTED by the author: run it, read the errors, fix them (see README).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create function lome_today() returns date
language sql stable as $$ select (now() at time zone 'Africa/Lome')::date $$;

create function auth_pharmacy_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pharmacy_id from profiles where id = auth.uid() and active
$$;

create function auth_role() returns app_role
language sql stable security definer set search_path = public, pg_temp as $$
  select role from profiles where id = auth.uid() and active
$$;

create function is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid() and active), false)
$$;

-- Returns the caller's pharmacy id, or raises. Suspended pharmacies are locked out.
create function _member_pharmacy(p_manager_only boolean default false) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_pharm uuid; v_role app_role; v_status pharmacy_status;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  select p.pharmacy_id, p.role into v_pharm, v_role
    from profiles p where p.id = auth.uid() and p.active;
  if v_pharm is null or v_role not in ('manager', 'staff') then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;
  if p_manager_only and v_role <> 'manager' then
    raise exception 'Action réservée aux gérants' using errcode = '42501';
  end if;
  select status into v_status from pharmacies where id = v_pharm;
  if v_status = 'suspended' then
    raise exception 'Pharmacie suspendue' using errcode = '42501';
  end if;
  return v_pharm;
end $$;

create function _audit(p_pharmacy uuid, p_action text, p_details jsonb default '{}')
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into audit_log (actor, pharmacy_id, action, details)
  values (auth.uid(), p_pharmacy, p_action, coalesce(p_details, '{}'))
$$;

-- ---------------------------------------------------------------------------
-- The stock engine. Internal: not granted to any API role.
-- Locks the batch row (FOR UPDATE), so concurrent updates to the same batch are
-- serialised and every balance is computed from the latest committed value.
-- ---------------------------------------------------------------------------
create function _apply_movement(
  p_pharmacy uuid, p_batch uuid, p_type movement_type, p_delta int,
  p_reason text, p_actor uuid, p_request uuid)
returns stock_movements
language plpgsql set search_path = public, pg_temp as $$
declare
  v_batch batches; v_move stock_movements; v_new int; v_today date := lome_today();
begin
  -- Idempotency: a retried request returns the original movement.
  if p_request is not null then
    select * into v_move from stock_movements
      where pharmacy_id = p_pharmacy and request_id = p_request;
    if found then return v_move; end if;
  end if;

  select * into v_batch from batches
    where id = p_batch and pharmacy_id = p_pharmacy for update;
  if not found then
    raise exception 'Lot introuvable' using errcode = 'P0002';
  end if;

  if p_delta > 0 and v_batch.expiry_date < v_today then
    raise exception 'Lot périmé : impossible d''ajouter du stock' using errcode = '23514';
  end if;
  if p_type = 'dispense' and v_batch.expiry_date < v_today then
    raise exception 'Lot périmé : vente impossible' using errcode = '23514';
  end if;

  v_new := v_batch.quantity_on_hand + p_delta;
  if v_new < 0 then
    raise exception 'Stock insuffisant (disponible : %)', v_batch.quantity_on_hand
      using errcode = '23514';
  end if;

  update batches set quantity_on_hand = v_new where id = v_batch.id;

  insert into stock_movements
    (pharmacy_id, medicine_id, batch_id, movement_type, quantity_delta, balance_after,
     reason, performed_by, request_id)
  values
    (p_pharmacy, v_batch.medicine_id, v_batch.id, p_type, p_delta, v_new,
     nullif(trim(p_reason), ''), p_actor, p_request)
  returning * into v_move;

  -- Any stock update counts as a fresh verification of this product.
  update pharmacy_products set last_verified_at = now()
    where pharmacy_id = p_pharmacy and medicine_id = v_batch.medicine_id;

  return v_move;
exception
  when unique_violation then
    -- Two identical requests raced; the other one won. Return its result.
    if p_request is not null then
      select * into v_move from stock_movements
        where pharmacy_id = p_pharmacy and request_id = p_request;
      if found then return v_move; end if;
    end if;
    raise;
end $$;

-- Record incoming stock (creates the batch if it is new).
create function receive_stock(
  p_medicine_id uuid, p_batch_number text, p_expiry_date date, p_quantity int,
  p_supplier_id uuid default null, p_unit_cost_xof int default null,
  p_request_id uuid default null)
returns stock_movements
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_pharm uuid := _member_pharmacy();
  v_batch uuid;
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantité invalide' using errcode = '22023';
  end if;
  if p_expiry_date is null or p_expiry_date < lome_today() then
    raise exception 'Date de péremption dépassée ou absente' using errcode = '22023';
  end if;
  if coalesce(trim(p_batch_number), '') = '' then
    raise exception 'Numéro de lot requis' using errcode = '22023';
  end if;
  if not exists (select 1 from medicines m where m.id = p_medicine_id
                 and (m.approved or m.created_by_pharmacy = v_pharm)) then
    raise exception 'Médicament inconnu ou en attente d''approbation' using errcode = '22023';
  end if;
  if p_supplier_id is not null and not exists
     (select 1 from suppliers s where s.id = p_supplier_id and s.pharmacy_id = v_pharm) then
    raise exception 'Fournisseur invalide' using errcode = '22023';
  end if;

  insert into pharmacy_products (pharmacy_id, medicine_id)
    values (v_pharm, p_medicine_id) on conflict do nothing;

  insert into batches (pharmacy_id, medicine_id, batch_number, expiry_date, supplier_id, unit_cost_xof)
    values (v_pharm, p_medicine_id, trim(p_batch_number), p_expiry_date, p_supplier_id, p_unit_cost_xof)
    on conflict (pharmacy_id, medicine_id, batch_number, expiry_date) do nothing;

  select id into v_batch from batches
    where pharmacy_id = v_pharm and medicine_id = p_medicine_id
      and batch_number = trim(p_batch_number) and expiry_date = p_expiry_date;

  return _apply_movement(v_pharm, v_batch, 'receipt', p_quantity, null, auth.uid(), p_request_id);
end $$;

-- Dispense / damage / return / expiry write-off / adjustment on an existing batch.
-- p_quantity is always positive, except for 'adjustment' (positive or negative).
create function record_stock_movement(
  p_batch_id uuid, p_type movement_type, p_quantity int,
  p_reason text default null, p_request_id uuid default null)
returns stock_movements
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_pharm uuid := _member_pharmacy();
  v_delta int;
begin
  if p_type = 'receipt' then
    raise exception 'Utilisez receive_stock pour enregistrer une entrée' using errcode = '22023';
  end if;
  if p_type = 'adjustment' then
    if p_quantity is null or p_quantity = 0 then
      raise exception 'Quantité invalide' using errcode = '22023';
    end if;
    v_delta := p_quantity;
  else
    if p_quantity is null or p_quantity <= 0 then
      raise exception 'Quantité invalide' using errcode = '22023';
    end if;
    v_delta := -p_quantity;
  end if;
  if p_type <> 'dispense' and length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Le motif est obligatoire pour ce type de mouvement' using errcode = '22023';
  end if;
  return _apply_movement(v_pharm, p_batch_id, p_type, v_delta, p_reason, auth.uid(), p_request_id);
end $$;

-- ---------------------------------------------------------------------------
-- Pharmacy self-service
-- ---------------------------------------------------------------------------
create function add_medicine(
  p_generic_name text, p_brand_name text, p_strength text, p_dosage_form text,
  p_stock_unit text, p_identifier text default null)
returns medicines
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_pharm uuid := _member_pharmacy();
  v_med medicines;
begin
  insert into medicines (generic_name, brand_name, strength, dosage_form, stock_unit, identifier, created_by_pharmacy)
  values (trim(p_generic_name), trim(coalesce(p_brand_name, '')), trim(p_strength),
          trim(p_dosage_form), trim(p_stock_unit), nullif(trim(p_identifier), ''), v_pharm)
  on conflict (lower(generic_name), lower(brand_name), lower(strength), lower(dosage_form)) do nothing;

  select * into v_med from medicines
   where lower(generic_name) = lower(trim(p_generic_name))
     and lower(brand_name) = lower(trim(coalesce(p_brand_name, '')))
     and lower(strength) = lower(trim(p_strength))
     and lower(dosage_form) = lower(trim(p_dosage_form));
  perform _audit(v_pharm, 'medicine.add', jsonb_build_object('medicine_id', v_med.id));
  return v_med;
end $$;

create function set_min_stock(p_medicine_id uuid, p_min_stock int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy();
begin
  if p_min_stock is null or p_min_stock < 0 then
    raise exception 'Seuil invalide' using errcode = '22023';
  end if;
  update pharmacy_products set min_stock = p_min_stock
   where pharmacy_id = v_pharm and medicine_id = p_medicine_id;
  if not found then raise exception 'Produit introuvable' using errcode = 'P0002'; end if;
  perform _audit(v_pharm, 'product.min_stock',
    jsonb_build_object('medicine_id', p_medicine_id, 'min_stock', p_min_stock));
end $$;

-- Manager only: decide what is public. A product can be public only if the
-- pharmacy is verified and the medicine is in the approved catalogue.
create function set_product_listing(
  p_medicine_id uuid, p_public boolean,
  p_show_quantity boolean default false, p_price_xof int default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy(true);
begin
  if p_public then
    if (select status from pharmacies where id = v_pharm) <> 'verified' then
      raise exception 'Pharmacie non vérifiée : publication impossible' using errcode = '42501';
    end if;
    if not exists (select 1 from medicines where id = p_medicine_id and approved) then
      raise exception 'Médicament non approuvé : publication impossible' using errcode = '42501';
    end if;
  end if;
  update pharmacy_products
     set public_listing = p_public,
         show_quantity  = p_public and coalesce(p_show_quantity, false),
         price_xof      = p_price_xof
   where pharmacy_id = v_pharm and medicine_id = p_medicine_id;
  if not found then raise exception 'Produit introuvable' using errcode = 'P0002'; end if;
  perform _audit(v_pharm, 'product.listing', jsonb_build_object(
    'medicine_id', p_medicine_id, 'public', p_public, 'show_quantity', p_show_quantity));
end $$;

-- Manager only: switch the whole pharmacy listing on or off.
create function set_pharmacy_listing(p_enabled boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy(true);
begin
  if p_enabled and (select status from pharmacies where id = v_pharm) <> 'verified' then
    raise exception 'Pharmacie non vérifiée : publication impossible' using errcode = '42501';
  end if;
  update pharmacies set listing_enabled = p_enabled where id = v_pharm;
  perform _audit(v_pharm, 'pharmacy.listing', jsonb_build_object('enabled', p_enabled));
end $$;

-- Manager only: public contact details and alert settings.
create function update_pharmacy_settings(
  p_phone_public text, p_opening_hours text, p_stale_after_hours int,
  p_expiry_warning_days int, p_unusual_adjustment_threshold int)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy(true);
begin
  update pharmacies set
    phone_public = nullif(trim(p_phone_public), ''),
    opening_hours = coalesce(nullif(trim(p_opening_hours), ''), opening_hours),
    stale_after_hours = coalesce(p_stale_after_hours, stale_after_hours),
    expiry_warning_days = coalesce(p_expiry_warning_days, expiry_warning_days),
    unusual_adjustment_threshold = coalesce(p_unusual_adjustment_threshold, unusual_adjustment_threshold)
  where id = v_pharm;
  perform _audit(v_pharm, 'pharmacy.settings', '{}');
end $$;

-- Staff or manager: "my stock information is up to date" (one product, or all).
create function confirm_availability(p_medicine_id uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy();
begin
  update pharmacy_products set last_verified_at = now()
   where pharmacy_id = v_pharm and (p_medicine_id is null or medicine_id = p_medicine_id);
  perform _audit(v_pharm, 'availability.confirm', jsonb_build_object('medicine_id', p_medicine_id));
end $$;

-- Manager only: attach an EXISTING auth user (invited through Supabase Auth) to the pharmacy.
create function assign_member(p_user_id uuid, p_full_name text, p_role app_role) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy(true);
begin
  if p_role not in ('manager', 'staff') then
    raise exception 'Rôle invalide' using errcode = '22023';
  end if;
  if exists (select 1 from profiles where id = p_user_id) then
    raise exception 'Cet utilisateur a déjà un profil' using errcode = '23505';
  end if;
  insert into profiles (id, full_name, role, pharmacy_id) values (p_user_id, trim(p_full_name), p_role, v_pharm);
  perform _audit(v_pharm, 'member.assign', jsonb_build_object('user', p_user_id, 'role', p_role));
end $$;

create function set_member_active(p_user_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pharm uuid := _member_pharmacy(true);
begin
  if p_user_id = auth.uid() then
    raise exception 'Vous ne pouvez pas modifier votre propre compte' using errcode = '22023';
  end if;
  update profiles set active = p_active where id = p_user_id and pharmacy_id = v_pharm;
  if not found then raise exception 'Utilisateur introuvable' using errcode = 'P0002'; end if;
  perform _audit(v_pharm, 'member.active', jsonb_build_object('user', p_user_id, 'active', p_active));
end $$;

-- ---------------------------------------------------------------------------
-- Registration and administration
-- ---------------------------------------------------------------------------
-- Any signed-in user without a profile can register a pharmacy. It starts as
-- 'pending' and cannot publish anything until a platform admin verifies it.
create function register_pharmacy(
  p_name text, p_address text, p_neighborhood text, p_phone text, p_email text,
  p_opening_hours text, p_authorization_ref text, p_full_name text,
  p_accept_terms boolean, p_terms_version text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'Ce compte est déjà rattaché à une pharmacie' using errcode = '23505';
  end if;
  if not coalesce(p_accept_terms, false) then
    raise exception 'Vous devez accepter les conditions d''utilisation et la politique de confidentialité'
      using errcode = '22023';
  end if;
  insert into pharmacies (name, address, neighborhood, phone, email, opening_hours,
                          authorization_ref, terms_accepted_at, terms_version)
  values (trim(p_name), trim(p_address), trim(p_neighborhood), trim(p_phone), trim(p_email),
          trim(p_opening_hours), trim(p_authorization_ref), now(), p_terms_version)
  returning id into v_id;
  insert into profiles (id, full_name, role, pharmacy_id)
  values (auth.uid(), trim(p_full_name), 'manager', v_id);
  perform _audit(v_id, 'pharmacy.register', jsonb_build_object('terms_version', p_terms_version));
  return v_id;
end $$;

create function admin_set_pharmacy_status(p_pharmacy uuid, p_status pharmacy_status) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not is_platform_admin() then
    raise exception 'Réservé aux administrateurs de la plateforme' using errcode = '42501';
  end if;
  update pharmacies set
    status = p_status,
    listing_enabled = listing_enabled and p_status = 'verified',
    verified_at = case when p_status = 'verified' then now() else verified_at end,
    verified_by = case when p_status = 'verified' then auth.uid() else verified_by end
  where id = p_pharmacy;
  if not found then raise exception 'Pharmacie introuvable' using errcode = 'P0002'; end if;
  perform _audit(p_pharmacy, 'admin.status', jsonb_build_object('status', p_status));
end $$;

create function admin_approve_medicine(p_medicine_id uuid, p_approved boolean default true) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not is_platform_admin() then
    raise exception 'Réservé aux administrateurs de la plateforme' using errcode = '42501';
  end if;
  update medicines set approved = p_approved where id = p_medicine_id;
  if not found then raise exception 'Médicament introuvable' using errcode = 'P0002'; end if;
  perform _audit(null, 'admin.medicine_approval',
    jsonb_build_object('medicine_id', p_medicine_id, 'approved', p_approved));
end $$;

-- ---------------------------------------------------------------------------
-- PUBLIC API (callable by anonymous visitors). Public users never touch tables:
-- these functions return a fixed, safe set of columns and nothing else
-- (no costs, suppliers, staff, e-mails, batch numbers, or hidden quantities).
-- Expiry and staleness are evaluated at read time, so nothing can go stale silently.
-- ---------------------------------------------------------------------------
create function public_search_medicines(p_query text)
returns table (id uuid, generic_name text, brand_name text, strength text, dosage_form text, stock_unit text)
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select m.id, m.generic_name, m.brand_name, m.strength, m.dosage_form, m.stock_unit
  from medicines m
  where m.approved
    and length(trim(coalesce(p_query, ''))) >= 2
    -- every word typed by the visitor must appear somewhere in name, brand, strength or form
    and not exists (
      select 1
      from regexp_split_to_table(unaccent(lower(trim(p_query))), '\s+') as w(word)
      where w.word <> ''
        and position(w.word in unaccent(lower(
              m.generic_name || ' ' || m.brand_name || ' ' || m.strength || ' ' || m.dosage_form))) = 0
    )
  order by m.generic_name, m.strength, m.dosage_form
  limit 30
$$;

-- Availability of ONE exact medicine (a specific strength + dosage form).
-- availability: 'available' | 'confirm' | 'unavailable'
--   confirm     = the pharmacy's information is older than its stale_after_hours
--   available   = fresh information AND eligible stock (non-expired batches only)
--   unavailable = fresh information AND no eligible stock
create function public_availability(p_medicine_id uuid, p_neighborhood text default null)
returns table (
  pharmacy_id uuid, pharmacy_name text, address text, neighborhood text,
  phone text, opening_hours text, latitude numeric, longitude numeric,
  availability text, last_verified_at timestamptz, price_xof int,
  eligible_quantity int, is_demo boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select * from (
    with elig as (
      select b.pharmacy_id, sum(b.quantity_on_hand)::int as qty
      from batches b
      where b.medicine_id = p_medicine_id
        and b.expiry_date >= lome_today()
        and b.quantity_on_hand > 0
      group by b.pharmacy_id
    )
    select ph.id, ph.name, ph.address, ph.neighborhood, ph.phone_public, ph.opening_hours,
           ph.latitude, ph.longitude,
           case
             when pp.last_verified_at < now() - make_interval(hours => ph.stale_after_hours) then 'confirm'
             when coalesce(e.qty, 0) > 0 then 'available'
             else 'unavailable'
           end as availability,
           pp.last_verified_at, pp.price_xof,
           case when pp.show_quantity then coalesce(e.qty, 0) end as eligible_quantity,
           ph.is_demo
    from pharmacy_products pp
    join pharmacies ph on ph.id = pp.pharmacy_id
    join medicines m  on m.id = pp.medicine_id
    left join elig e  on e.pharmacy_id = pp.pharmacy_id
    where pp.medicine_id = p_medicine_id
      and pp.public_listing and m.approved
      and ph.status = 'verified' and ph.listing_enabled
      and (coalesce(p_neighborhood, '') = '' or lower(ph.neighborhood) = lower(p_neighborhood))
  ) t
  order by case t.availability when 'available' then 0 when 'confirm' then 1 else 2 end, t.name
$$;

create function public_pharmacy_directory()
returns table (id uuid, name text, address text, neighborhood text, phone text,
               opening_hours text, latitude numeric, longitude numeric, is_demo boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select ph.id, ph.name, ph.address, ph.neighborhood, ph.phone_public, ph.opening_hours,
         ph.latitude, ph.longitude, ph.is_demo
  from pharmacies ph
  where ph.status = 'verified' and ph.listing_enabled
  order by ph.name
$$;

-- ---------------------------------------------------------------------------
-- Private views (security_invoker: the caller's row-level security applies,
-- so each pharmacy only ever sees its own rows).
-- ---------------------------------------------------------------------------
create view v_stock_levels with (security_invoker = true) as
select pp.pharmacy_id, pp.medicine_id,
       m.generic_name, m.brand_name, m.strength, m.dosage_form, m.stock_unit,
       pp.min_stock, pp.public_listing, pp.last_verified_at,
       coalesce(sum(b.quantity_on_hand) filter (where b.expiry_date >= lome_today()), 0)::int as eligible_qty,
       coalesce(sum(b.quantity_on_hand) filter (where b.expiry_date <  lome_today()), 0)::int as expired_qty,
       min(b.expiry_date) filter (where b.expiry_date >= lome_today() and b.quantity_on_hand > 0) as next_expiry
from pharmacy_products pp
join medicines m on m.id = pp.medicine_id
left join batches b on b.pharmacy_id = pp.pharmacy_id and b.medicine_id = pp.medicine_id
group by pp.pharmacy_id, pp.medicine_id, m.generic_name, m.brand_name, m.strength,
         m.dosage_form, m.stock_unit, pp.min_stock, pp.public_listing, pp.last_verified_at;

create view v_alerts with (security_invoker = true) as
  select pharmacy_id, 'zero_stock'::text as alert_type, medicine_id, null::uuid as batch_id,
         'Aucun stock éligible'::text as detail, now() as noted_at
  from v_stock_levels where eligible_qty = 0
union all
  select pharmacy_id, 'low_stock', medicine_id, null::uuid,
         'Stock bas : ' || eligible_qty || ' (seuil ' || min_stock || ')', now()
  from v_stock_levels where eligible_qty > 0 and eligible_qty <= min_stock
union all
  select b.pharmacy_id, 'expiring_soon', b.medicine_id, b.id,
         'Lot ' || b.batch_number || ' expire le ' || b.expiry_date, now()
  from batches b join pharmacies ph on ph.id = b.pharmacy_id
  where b.quantity_on_hand > 0 and b.expiry_date >= lome_today()
    and b.expiry_date <= lome_today() + ph.expiry_warning_days
union all
  select b.pharmacy_id, 'expired_stock', b.medicine_id, b.id,
         'Lot ' || b.batch_number || ' périmé (' || b.quantity_on_hand || ' unités exclues du stock)', now()
  from batches b
  where b.quantity_on_hand > 0 and b.expiry_date < lome_today()
union all
  select sm.pharmacy_id, 'unusual_adjustment', sm.medicine_id, sm.batch_id,
         'Ajustement de ' || sm.quantity_delta || ' : ' || coalesce(sm.reason, ''), sm.created_at
  from stock_movements sm join pharmacies ph on ph.id = sm.pharmacy_id
  where sm.movement_type = 'adjustment'
    and abs(sm.quantity_delta) >= ph.unusual_adjustment_threshold
    and sm.created_at > now() - interval '7 days';

create view v_inventory_report with (security_invoker = true) as
select b.pharmacy_id, m.generic_name, m.brand_name, m.strength, m.dosage_form, m.stock_unit,
       b.batch_number, b.expiry_date, b.quantity_on_hand,
       case when b.expiry_date < lome_today() then 'expired' else 'valid' end as batch_state,
       s.name as supplier_name, b.unit_cost_xof
from batches b
join medicines m on m.id = b.medicine_id
left join suppliers s on s.id = b.supplier_id;

create view v_movement_report with (security_invoker = true) as
select sm.pharmacy_id, sm.created_at, m.generic_name, m.brand_name, m.strength, m.dosage_form,
       b.batch_number, sm.movement_type, sm.quantity_delta, sm.balance_after, sm.reason,
       coalesce(p.full_name, 'Système') as staff_member
from stock_movements sm
join medicines m on m.id = sm.medicine_id
join batches b on b.id = sm.batch_id
left join profiles p on p.id = sm.performed_by;

-- Integrity check for operators (not exposed to the API): every cached balance
-- must equal the sum of its ledger entries. Returns rows only if something is wrong.
create function check_ledger_consistency()
returns table (batch_id uuid, cached_qty int, ledger_qty bigint)
language sql stable as $$
  select b.id, b.quantity_on_hand, coalesce(sum(sm.quantity_delta), 0)
  from batches b left join stock_movements sm on sm.batch_id = b.id
  group by b.id, b.quantity_on_hand
  having b.quantity_on_hand <> coalesce(sum(sm.quantity_delta), 0)
$$;
