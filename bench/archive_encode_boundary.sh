#!/usr/bin/env bash
# Run tests/archive/db/10_encode_boundary_test.sql against an ARBITRARY copy of
# pgpm_archive/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. The boundary test is a plain pgTAP file and the archive track
# already runs it every time, so this script adds nothing on correct code. What it adds is the
# standing proof that it DISCRIMINATES. #408's assertions are negatives ("the payload landed as a
# quoted identifier, not as SQL", "the victim table is still there"), and a negative is also
# satisfied by a test that never reached the code it is about -- the failure mode this repo has
# shipped six times. That proof was originally obtained by hand, once, against two hand-planted
# regressions; run_archive's pg_prove has no way to re-obtain it, and evidence that lives in a
# commit message decays immediately. Pointing the same file at a mutant turns it into a check.
#
# The two mutations it is required to fail against (bench/mutations/mutate.py):
#   archive_from_item_raw_splice  -- %I weakened to %s in archive._pq_from_item, i.e. the FROM item
#                                    pasted in unquoted, which is exactly what p_from_sql used to be
#   archive_order_by_raw_splice   -- quote_ident dropped from the ORDER BY build, i.e. p_order_by's
#                                    elements pasted in unquoted, which is what p_order_by used to be
#
# Usage: archive_encode_boundary.sh <container> <db> [archive install.sql]
# Needs the archive image (pgsql-http + pgtap + pg_prove), not the plain core one.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
TEST_FILE=/repo/tests/archive/db/10_encode_boundary_test.sql
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }

q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: the guard would then be reported as failing
# for a reason that has nothing to do with what it asserts. Say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "no"
  fail=1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the archive module under test installed" "$ARCHIVE_INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^(not )?ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's own exit status already covers "fewer assertions ran than the plan promised" -- a
  # file that dies early reports a bad plan and exits non-zero. What it cannot tell us apart from
  # a real failure is a run that never reached the database at all, and in THIS script that
  # distinction matters more than usual: discriminate.sh reads a non-zero exit as "the guard
  # caught the defect", so a harness broken enough to fail against everything would be reported as
  # proving every mutation. Hence the count, asserted separately and printed either way.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the boundary assertions hold" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the boundary assertions hold" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
