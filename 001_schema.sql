-- PharmaStock - 001: schema
-- Target: PostgreSQL 15 (Supabase). Run the migrations in order: 001, 002, 003.
-- NOT YET EXECUTED by the author: run it, read the errors, fix them (see README).

create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;

create type app_role        as enum ('admin', 'manager', 'staff');
create type pharmacy_status as enum ('pending', 'verified', 'suspended');
create type movement_type   as enum
  ('receipt', 'dispense', 'damage', 'return_to_supplier', 'expiry_writeoff', 'adjustment');

-- ---------------------------------------------------------------------------
-- Pharmacies. Private fields (phone, email, authorization_ref) are never
-- returned by the public functions in 002.
-- ---------------------------------------------------------------------------
create table pharmacies (
  id                           uuid primary key default gen_random_uuid(),
  name                         text not null check (length(trim(name)) > 1),
  address                      text not null,
  neighborhood                 text not null,
  city                         text not null default 'Lomé',
  latitude                     numeric(9,6),
  longitude                    numeric(9,6),
  phone                        text not null,          -- private contact number
  phone_public                 text,                   -- shown publicly only if the pharmacy provides it
  email                        text not null,
  opening_hours                text not null,
  authorization_ref            text not null,          -- professional authorization details (checked by an admin)
  status                       pharmacy_status not null default 'pending',
  listing_enabled              boolean not null default false,
  stale_after_hours            int not null default 48  check (stale_after_hours between 1 and 720),
  expiry_warning_days          int not null default 90  check (expiry_warning_days between 1 and 365),
  unusual_adjustment_threshold int not null default 20  check (unusual_adjustment_threshold > 0),
  is_demo                      boolean not null default false,
  terms_accepted_at            timestamptz not null,
  terms_version                text not null,
  verified_at                  timestamptz,
  verified_by                  uuid,
  created_at                   timestamptz not null default now(),
  -- Unverified or suspended pharmacies can never be publicly listed.
  constraint listing_requires_verified check (not listing_enabled or status = 'verified')
);

-- ---------------------------------------------------------------------------
-- Staff accounts. Platform admins have no pharmacy; everyone else has exactly one.
-- ---------------------------------------------------------------------------
create table profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null,
  role        app_role not null,
  pharmacy_id uuid references pharmacies (id),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint admin_has_no_pharmacy check ((role = 'admin') = (pharmacy_id is null))
);

-- ---------------------------------------------------------------------------
-- Shared medicine catalogue. Strength and dosage form are part of the identity:
-- "Paracetamol 500 mg tablet" and "Paracetamol 1000 mg tablet" are different rows.
-- Medicines added by pharmacies stay private to them until an admin approves them.
-- ---------------------------------------------------------------------------
create table medicines (
  id                  uuid primary key default gen_random_uuid(),
  generic_name        text not null check (length(trim(generic_name)) > 0),
  brand_name          text not null default '',
  strength            text not null check (length(trim(strength)) > 0),
  dosage_form         text not null check (length(trim(dosage_form)) > 0),
  stock_unit          text not null check (length(trim(stock_unit)) > 0),  -- e.g. boîte, plaquette, flacon
  identifier          text,                                               -- national code / registration number
  approved            boolean not null default false,
  created_by_pharmacy uuid references pharmacies (id),
  created_at          timestamptz not null default now()
);
create unique index medicines_identity_idx
  on medicines (lower(generic_name), lower(brand_name), lower(strength), lower(dosage_form));

create table suppliers (
  id          uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references pharmacies (id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  phone       text,
  created_at  timestamptz not null default now()
);
create unique index suppliers_name_idx on suppliers (pharmacy_id, lower(name));

-- One row per (pharmacy, medicine): thresholds and public-listing settings.
create table pharmacy_products (
  pharmacy_id      uuid not null references pharmacies (id) on delete cascade,
  medicine_id      uuid not null references medicines (id),
  min_stock        int not null default 0 check (min_stock >= 0),
  public_listing   boolean not null default false,   -- manager chooses what appears publicly
  show_quantity    boolean not null default false,   -- exact quantity is public only if enabled
  price_xof        int check (price_xof >= 0),       -- public selling price (not the purchase cost)
  last_verified_at timestamptz not null default now(),
  primary key (pharmacy_id, medicine_id)
);

-- Batches. quantity_on_hand is a cached balance that is ONLY changed by
-- _apply_movement() in the same transaction as the ledger insert.
-- Negative balances are impossible (see README, "decisions").
create table batches (
  id               uuid primary key default gen_random_uuid(),
  pharmacy_id      uuid not null,
  medicine_id      uuid not null,
  batch_number     text not null check (length(trim(batch_number)) > 0),
  expiry_date      date not null,                   -- last day the batch is valid (inclusive)
  supplier_id      uuid references suppliers (id),
  unit_cost_xof    int check (unit_cost_xof >= 0),  -- private purchase cost
  quantity_on_hand int not null default 0 check (quantity_on_hand >= 0),
  created_at       timestamptz not null default now(),
  foreign key (pharmacy_id, medicine_id) references pharmacy_products (pharmacy_id, medicine_id),
  unique (pharmacy_id, medicine_id, batch_number, expiry_date)
);
create index batches_lookup_idx on batches (pharmacy_id, medicine_id, expiry_date);

-- The ledger: append-only, the source of truth for balances.
create table stock_movements (
  id             bigint generated always as identity primary key,
  pharmacy_id    uuid not null references pharmacies (id),
  medicine_id    uuid not null references medicines (id),
  batch_id       uuid not null references batches (id),
  movement_type  movement_type not null,
  quantity_delta int not null check (quantity_delta <> 0),
  balance_after  int not null check (balance_after >= 0),
  reason         text,
  performed_by   uuid,            -- auth user id; no FK on purpose, so the audit trail survives account deletion
  request_id     uuid,            -- client-generated idempotency key (safe retries on poor connections)
  created_at     timestamptz not null default now(),
  constraint sign_matches_type check (
       (movement_type = 'receipt' and quantity_delta > 0)
    or (movement_type in ('dispense', 'damage', 'return_to_supplier', 'expiry_writeoff') and quantity_delta < 0)
    or (movement_type = 'adjustment')),
  constraint reason_required check (
       movement_type in ('receipt', 'dispense')
    or length(trim(coalesce(reason, ''))) >= 3)
);
create unique index stock_movements_request_idx
  on stock_movements (pharmacy_id, request_id) where request_id is not null;
create index stock_movements_pharmacy_time_idx on stock_movements (pharmacy_id, created_at desc);
create index stock_movements_batch_idx on stock_movements (batch_id);

-- Audit trail for everything that is not a stock movement.
create table audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  pharmacy_id uuid,
  action      text not null,
  details     jsonb not null default '{}'
);
create index audit_log_pharmacy_idx on audit_log (pharmacy_id, at desc);

-- Append-only enforcement, for everybody including the table owner.
create function forbid_change() returns trigger language plpgsql as $$
begin
  raise exception 'La table % est en ajout seul (append-only)', tg_table_name using errcode = '42501';
end $$;

create trigger stock_movements_append_only before update or delete on stock_movements
  for each row execute function forbid_change();
create trigger stock_movements_no_truncate before truncate on stock_movements
  for each statement execute function forbid_change();
create trigger audit_log_append_only before update or delete on audit_log
  for each row execute function forbid_change();
create trigger audit_log_no_truncate before truncate on audit_log
  for each statement execute function forbid_change();
