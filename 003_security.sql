-- PharmaStock - 003: privileges and row-level security
-- Principle: deny everything, then grant the minimum.
--   * Anonymous visitors can run exactly three read-only public functions.
--   * Signed-in pharmacy users can READ their own pharmacy's rows and call the
--     stock/admin functions from 002. They cannot write to stock tables directly.
-- NOT YET EXECUTED by the author: run it, read the errors, fix them (see README).

grant usage on schema public to anon, authenticated;

-- 1. Remove every default privilege (Supabase grants broad access by default).
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon, authenticated;

-- 2. Row-level security on every table.
alter table pharmacies        enable row level security;
alter table profiles          enable row level security;
alter table medicines         enable row level security;
alter table suppliers         enable row level security;
alter table pharmacy_products enable row level security;
alter table batches           enable row level security;
alter table stock_movements   enable row level security;
alter table audit_log         enable row level security;

-- 3. Read policies: a user sees only their own pharmacy's rows.
--    Platform admins see pharmacies, profiles and the medicine catalogue,
--    but NOT any pharmacy's inventory, suppliers, or movements.
create policy pharmacies_read on pharmacies for select to authenticated
  using (id = auth_pharmacy_id() or is_platform_admin());

create policy profiles_read on profiles for select to authenticated
  using (id = auth.uid() or pharmacy_id = auth_pharmacy_id() or is_platform_admin());

create policy medicines_read on medicines for select to authenticated
  using (approved or created_by_pharmacy = auth_pharmacy_id() or is_platform_admin());

create policy suppliers_read on suppliers for select to authenticated
  using (pharmacy_id = auth_pharmacy_id());
create policy suppliers_insert on suppliers for insert to authenticated
  with check (pharmacy_id = auth_pharmacy_id());
create policy suppliers_update on suppliers for update to authenticated
  using (pharmacy_id = auth_pharmacy_id())
  with check (pharmacy_id = auth_pharmacy_id());

create policy products_read on pharmacy_products for select to authenticated
  using (pharmacy_id = auth_pharmacy_id());
create policy batches_read on batches for select to authenticated
  using (pharmacy_id = auth_pharmacy_id());
create policy movements_read on stock_movements for select to authenticated
  using (pharmacy_id = auth_pharmacy_id());

create policy audit_read on audit_log for select to authenticated
  using ((pharmacy_id = auth_pharmacy_id() and auth_role() = 'manager') or is_platform_admin());

-- 4. Table privileges. No INSERT/UPDATE/DELETE anywhere except suppliers:
--    all other writes go through the SECURITY DEFINER functions.
grant select on pharmacies, profiles, medicines, suppliers, pharmacy_products,
                batches, stock_movements, audit_log to authenticated;
grant insert, update on suppliers to authenticated;
grant select on v_stock_levels, v_alerts, v_inventory_report, v_movement_report to authenticated;

-- 5. Function privileges.
grant execute on function
  auth_pharmacy_id(), auth_role(), is_platform_admin(), lome_today()
  to authenticated;

grant execute on function
  receive_stock(uuid, text, date, int, uuid, int, uuid),
  record_stock_movement(uuid, movement_type, int, text, uuid),
  add_medicine(text, text, text, text, text, text),
  set_min_stock(uuid, int),
  set_product_listing(uuid, boolean, boolean, int),
  set_pharmacy_listing(boolean),
  update_pharmacy_settings(text, text, int, int, int),
  confirm_availability(uuid),
  assign_member(uuid, text, app_role),
  set_member_active(uuid, boolean),
  register_pharmacy(text, text, text, text, text, text, text, text, boolean, text),
  admin_set_pharmacy_status(uuid, pharmacy_status),
  admin_approve_medicine(uuid, boolean)
  to authenticated;

-- The only things anonymous visitors can call:
grant execute on function
  public_search_medicines(text),
  public_availability(uuid, text),
  public_pharmacy_directory()
  to anon, authenticated;

-- Not granted to anyone on purpose: _apply_movement, _member_pharmacy, _audit,
-- check_ledger_consistency (operators run it as the database owner).

-- NOTE: any function you add later is executable by PUBLIC by default.
-- Always follow "create function ..." with an explicit revoke/grant.
