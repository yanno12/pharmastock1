#!/usr/bin/env bash
# PharmaStock - concurrency test.
#
# Fires many simultaneous "sell 1 unit" requests, from separate database sessions,
# at ONE batch that holds fewer units than there are requests, then checks that:
#   - exactly STOCK sales succeeded (no overselling),
#   - the final balance is 0 (never negative),
#   - the ledger and the cached balance agree.
#
# It COMMITS test data and the ledger is append-only, so run it ONLY on a throwaway
# database (e.g. after `supabase db reset`), and reset the database afterwards.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
#     bash tests/concurrency.sh
# Optional: WORKERS=150 STOCK=100 PARALLEL=25
#
# NOT YET EXECUTED by the author: expect to fix small errors on the first run.

set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL to a THROWAWAY database}"

WORKERS="${WORKERS:-150}"
STOCK="${STOCK:-100}"
PARALLEL="${PARALLEL:-25}"

TEST_UID="c0c0c0c0-0000-4000-8000-000000000001"
PHARMACY_ID="c0c0c0c0-0000-4000-8000-0000000000ff"
MEDICINE_ID="c0c0c0c0-0000-4000-8000-0000000000fe"
BATCH_ID="c0c0c0c0-0000-4000-8000-0000000000fd"
export DATABASE_URL TEST_UID BATCH_ID

run_sql() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "Setting up test pharmacy with $STOCK units in one batch..."
run_sql <<SQL
insert into auth.users (id, email) values ('$TEST_UID', 'concurrency@test.invalid');
insert into pharmacies (id, name, address, neighborhood, phone, email, opening_hours,
                        authorization_ref, status, is_demo, terms_accepted_at, terms_version)
  values ('$PHARMACY_ID', '[TEST] Concurrence', 'x', 'x', 'x', 'x@example.invalid', 'x',
          'TEST', 'verified', true, now(), 'test');
insert into profiles (id, full_name, role, pharmacy_id)
  values ('$TEST_UID', 'Testeur', 'manager', '$PHARMACY_ID');
insert into medicines (id, generic_name, strength, dosage_form, stock_unit, approved)
  values ('$MEDICINE_ID', 'TestMed', '1 mg', 'comprimé', 'boîte', true);
insert into pharmacy_products (pharmacy_id, medicine_id) values ('$PHARMACY_ID', '$MEDICINE_ID');
insert into batches (id, pharmacy_id, medicine_id, batch_number, expiry_date)
  values ('$BATCH_ID', '$PHARMACY_ID', '$MEDICINE_ID', 'CONC-1', current_date + 365);
select _apply_movement('$PHARMACY_ID', '$BATCH_ID', 'receipt', $STOCK, 'Stock initial du test', null, null);
SQL

# One worker = one separate session acting as the pharmacy manager.
worker() {
  if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
begin;
select set_config('request.jwt.claim.sub', '$TEST_UID', true);
set local role authenticated;
select record_stock_movement('$BATCH_ID', 'dispense', 1, null, gen_random_uuid());
commit;
SQL
  then echo ok; else echo fail; fi
}
export -f worker

echo "Launching $WORKERS sales ($PARALLEL at a time)..."
RESULT="$(seq "$WORKERS" | xargs -P "$PARALLEL" -I{} bash -c worker | sort | uniq -c)"
echo "$RESULT"

OK_COUNT="$(echo "$RESULT" | awk '$2=="ok"{print $1}')"; OK_COUNT="${OK_COUNT:-0}"
FINAL="$(run_sql -At -c "select quantity_on_hand from batches where id = '$BATCH_ID'")"
MOVES="$(run_sql -At -c "select count(*) from stock_movements where batch_id = '$BATCH_ID' and movement_type = 'dispense'")"
BAD="$(run_sql -At -c "select count(*) from check_ledger_consistency()")"

EXPECT_SOLD=$(( WORKERS < STOCK ? WORKERS : STOCK ))
EXPECT_FINAL=$(( STOCK - EXPECT_SOLD ))

echo "Sales succeeded:     $OK_COUNT   (expected $EXPECT_SOLD)"
echo "Ledger sale entries: $MOVES   (expected $EXPECT_SOLD)"
echo "Final balance:       $FINAL   (expected $EXPECT_FINAL)"
echo "Ledger mismatches:   $BAD   (expected 0)"

if [ "$OK_COUNT" -eq "$EXPECT_SOLD" ] && [ "$MOVES" -eq "$EXPECT_SOLD" ] \
   && [ "$FINAL" -eq "$EXPECT_FINAL" ] && [ "$BAD" -eq 0 ]; then
  echo "CONCURRENCY TEST PASSED"
else
  echo "CONCURRENCY TEST FAILED"; exit 1
fi
