#!/usr/bin/env bash
# Run tests/129_set_regrain_off_midflight_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its load-bearing assertions are negatives -- "no child carries
# capture", "no copy is recorded", "TRUNCATE is not refused", "three later ticks did nothing" -- and a
# negative is equally satisfied by a run in which no regrain was ever in flight, which is the failure mode
# this repo has shipped six times. The file pins its setup with liveness witnesses of its own (capture
# really sat on the source, the cursor really was set, an update really landed in the delta, TRUNCATE
# really was refused), but nothing re-checks that those witnesses would still fail if the abandonment they
# guard were removed. Pointing the same file at a mutant is what checks that, every CI run, instead of
# once by hand in a commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   set_regrain_off_keeps_regrain  -- set_regrain(parent, null) writes regrain_to and nothing else again,
#                                     which is pre-#516 behaviour exactly: the run in flight is neither
#                                     driven (maintain dispatches only while regrain_to is set) nor swept
#                                     (the janitor keeps capture on the child covering the cursor, which
#                                     nothing clears), so capture, the TRUNCATE refusal, the delta and the
#                                     copies all stay, and tests/129's section (A) is what catches it
#
# Usage: set_regrain_off_midflight.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# SET_REGRAIN_OFF_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${SET_REGRAIN_OFF_TEST_FILE:-/repo/tests/129_set_regrain_off_midflight_test.sql}"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for a
# reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised". What it cannot
  # tell us apart from a real failure is a run that never reached the database at all, and here that
  # matters more than usual: discriminate.sh reads a non-zero exit as "the guard caught the defect", so a
  # harness broken enough to fail against everything would be reported as proving the mutation. Hence the
  # count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "turning auto-regrain off abandons the run it had in flight" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "turning auto-regrain off abandons the run it had in flight" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
