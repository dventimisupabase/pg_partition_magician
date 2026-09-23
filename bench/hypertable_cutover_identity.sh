#!/usr/bin/env bash
# Run tests/timescale/db/17_from_hypertable_cutover_identity_test.sql against an ARBITRARY copy of
# pgpm_hypertable/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the timescale track already runs
# it, so this script adds nothing on correct code. What it adds is the standing proof that its #422
# assertions DISCRIMINATE -- and here that proof carries more weight than usual, because of a
# constraint the test file itself documents at length: run_timescale fails the track on any `ERROR:`
# line, so the cutover has to be wrapped by throws_like, and a procedure reaching its own COMMIT
# inside a function raises `invalid transaction termination`. A cutover that WRONGLY succeeds
# therefore cannot be observed committing -- it dies at its commit and rolls back into the same end
# state as a correct refusal. The refusal's own message is the only thing that separates them, so
# "the message is asserted exactly" is not stylistic here; it is the whole guard, and pointing the
# file at a mutant is the only way to know the message assertion is load-bearing rather than
# incidental.
#
# TWO mutations are required to fail against it, one per half of the swap, and each must break ONLY
# its own half -- which is how a failure says which half went missing (bench/mutations/mutate.py):
#   hypertable_cutover_unverified_source -- the by-name lock restored, no re-resolve. Breaks PART A.
#   hypertable_cutover_unverified_dest   -- the destination lock-and-verify deleted. Breaks PART B.
#
# Usage: hypertable_cutover_identity.sh <container> <db> [pgpm_hypertable/install.sql]
# Runs on the TIMESCALE track's container (supabase/postgres + TimescaleDB), which is why these
# mutations sit in their own MUTATION_TRACK rather than the default one: `./test.sh discriminate`
# must stay runnable on a laptop without that image, exactly as for locktrace.
#
# psql, not pg_prove: the supabase/postgres image has no pg_prove, which is why run_timescale parses
# TAP out of psql -tAq itself. This does the same, including the ERROR: check -- a mutant that dies
# with a raw error instead of a failed assertion must not read as a pass.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; HT="${3:-/repo/pgpm_hypertable/install.sql}"
TEST_FILE=/repo/tests/timescale/db/17_from_hypertable_cutover_identity_test.sql
fail=0

q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@"; }

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened. The core goes in first
# and is never the mutated file -- only pgpm_hypertable is.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$HT"
  fail=1
fi
if [ "$fail" = 0 ] && ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1)
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+ -')
  # Two failure shapes, reported apart. A file that died early leaves a raw ERROR: and few or no
  # assertions, which must NOT read the same as assertions that ran and failed -- discriminate.sh
  # treats any non-zero exit as "the guard caught the defect", so a harness broken enough to fail
  # against everything would otherwise be reported as proving the mutation.
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "the cutover verifies both halves of the swap" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "the cutover verifies both halves of the swap" "$ran ran, $bad failed"; fail=1
  fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
