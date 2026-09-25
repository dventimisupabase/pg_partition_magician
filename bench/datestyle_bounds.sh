#!/usr/bin/env bash
# Run tests/124_datestyle_independent_bounds_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. Same reason as bench/grid_timezone.sh, which spells it out at length: the
# file is a plain pgTAP file that the default matrix already runs on every version and channel, so this
# script adds nothing on correct code. What it adds is the standing proof that the file DISCRIMINATES.
# Its decisive assertions are identities ("the stored hi is '2026-10-01 00:00:00+00'", "read from an
# ISO, MDY session it is the first of next month"), but the rows-survive and nothing-dropped assertions
# around them are negatives, and a negative is equally satisfied by a run that never set up the
# disagreement: a session that was not really on SQL, DMY, a tick that never reached its retain step. The
# file pins those with liveness witnesses of its own; pointing the same file at a mutant is what checks,
# every CI run, that the witnesses and the identities together would fail if the DateStyle pin were gone.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   datestyle_session_render -- pgpm._ts_text without its `set datestyle = 'ISO, MDY'` clause, so every
#                               native render follows the SESSION's DateStyle again, which is pre-#500
#                               behaviour exactly: a transmute under SQL, DMY stores '01/10/2026 ...' and
#                               the default-style maintain reads it as 10 January and drops the live
#                               monolith
#
# Usage: datestyle_bounds.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). DATESTYLE_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${DATESTYLE_TEST_FILE:-/repo/tests/124_datestyle_independent_bounds_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "native bounds mean the same instant in every DateStyle" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "native bounds mean the same instant in every DateStyle" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
