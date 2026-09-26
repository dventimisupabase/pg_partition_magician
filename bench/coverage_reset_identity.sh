#!/usr/bin/env bash
# Run tests/129_coverage_reset_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that its #518 assertions DISCRIMINATE. The load-bearing ones in part A are negatives
# -- "the ledger row is still there", "no archive_coverage_reset was logged" -- and a negative is
# equally satisfied by a write-block pass that never resets anything, which is the failure mode this
# repo has shipped six times. The file pins that with liveness witnesses of its own (the recorded
# child_oid, the substitute's different oid, the trigger still on the real relation, the archive step
# reaching the ledger for the untouched sibling in the same tick) and with part B, where the reset
# is required to FIRE on a partition whose identity is intact; but nothing re-checks that those
# witnesses would fail if the guard they guard were removed. Pointing the same file at a mutant is
# what checks that, every CI run, instead of once by hand in a commit message.
#
# TWO mutations are required to fail against it, and neither is redundant -- each is a different
# plausible way to get this wrong:
#   coverage_reset_by_name                 -- the identity predicate computed and ignored, so "coverage
#                                             without its block" is decided by the name alone again.
#                                             Pre-#518 behaviour exactly. Breaks PART A.
#   coverage_reset_unanchored_is_mismatch  -- the tempting consistency fix: `is distinct from`, the
#                                             form retire() and _archive_step use, which reads a null
#                                             child_oid as a substitution and keeps, for every
#                                             partition an install upgraded with, coverage nothing
#                                             vouches for. Breaks PART C only.
#
# Usage: coverage_reset_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE=/repo/tests/129_coverage_reset_identity_test.sql
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised" -- a file
  # that dies early reports a bad plan and exits non-zero. What it cannot tell us apart from a real
  # failure is a run that never reached the database at all, and in THIS script that distinction
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect",
  # so a harness broken enough to fail against everything would be reported as proving the mutation.
  # Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "coverage is discarded only from the relation pgpm identified" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "coverage is discarded only from the relation pgpm identified" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
