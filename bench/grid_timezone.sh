#!/usr/bin/env bash
# Run tests/111_grid_timezone_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Nearly every assertion in it is a negative -- "the two
# sessions agree", "every hi equals the next lo", "no hole across the fall-back" -- and a negative is
# equally satisfied by a run that never set up the disagreement at all, which is the failure mode this
# repo has shipped six times. The file pins its setup with liveness witnesses of its own (the New York
# and UTC month boundaries really are different instants, the chosen day really has a fall-back, the
# second builder really extended the grid), but nothing re-checks that those witnesses would fail if
# the zone pinning they guard were removed. Pointing the same file at a mutant is what checks that,
# every CI run, instead of once by hand in a commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   grid_session_timezone  -- _grid_next's calendar step evaluated in the SESSION's TimeZone again, the
#                             zone parameter accepted and ignored, which is pre-#455 behaviour exactly:
#                             a grid transmuted under New York and extended under UTC lands on two
#                             lattices, and the hole between them is what tests/111 walks for
#
# Usage: grid_timezone.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). GRID_TZ_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo, and is also how the other zone-class guards (bench/day_label_utc.sh and
# its siblings) drive THEIR pgTAP file through this same harness; GRID_TZ_LABEL names the property the
# PASS/FAIL line reports for that file.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${GRID_TZ_TEST_FILE:-/repo/tests/111_grid_timezone_test.sql}"
LABEL="${GRID_TZ_LABEL:-the grid is computed in the recorded zone, from any session}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
