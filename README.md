# PharmaStock app (French front end)

A static web app, with no build step, that talks to the PharmaStock database (the `pharmastock-db` project). It was written without access to a running Supabase, so **it has not been tested against a real database**. Expect small fixes on first run.

## Run it

1. Set up the database first (see `pharmastock-db/README.md`) and load the demo data.
2. Edit `config.js`: add your Supabase URL and the public anon key.
3. Serve this folder (opening the file directly may fail):
   ```
   cd pharmastock-app
   python3 -m http.server 8080
   ```
   Then open http://localhost:8080.

## What it does

- **Public finder (no login):** search, choose the exact strength and form, see pharmacies with DISPONIBLE / CONFIRMER LA DISPONIBILITÉ / INDISPONIBLE, last verification time, call and directions buttons, directory.
- **Accounts and registration:** sign up / log in, then register a pharmacy (terms acceptance required). It stays "pending" until an administrator verifies it.
- **Pharmacy dashboard:** key figures, alerts, record receipts, sales, breakage, returns, expiry write-offs and adjustments (with batch numbers and expiry dates), minimum stock, per-product publishing and price (managers), confirm stock is current, movement history, CSV export, add a medicine.
- **Administrator screen:** verify or suspend pharmacies, approve new medicines. Create the first administrator by inserting a `profiles` row with role `admin` (see `pharmastock-db/supabase/seed.sql`).

## Not included yet

- Supplier management screen (receipts can be recorded without a supplier).
- Staff invitations and user management (needs a small server-side function; see the database README).
- Map and GPS position, distance sorting, stock reports beyond the inventory CSV.
- Settings screen for stale-data hours and expiry warning days (the database supports them).
- The terms and privacy texts. Set `TERMS_URL` and `PRIVACY_URL` in `config.js`; do not launch without them.

## Security notes

All permissions are enforced by the database, not by this page. Hiding or changing buttons here grants nothing. Only the public anon key belongs in `config.js`.
