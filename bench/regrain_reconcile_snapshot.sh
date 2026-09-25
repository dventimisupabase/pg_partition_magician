#!/usr/bin/env bash
# Run tests/124_regrain_reconcile_snapshot_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its central assertion is a negative -- "T1's committed
# UPDATE is not reverted by the swap" -- and a negative is equally satisfied by a run in which T1
# committed after the tick had already finished, or before it started, so that no capture ever sat
# below the watermark uncommitted while the apply statements ran. The file pins its own setup with
# liveness witnesses (the tick was observed inside its apply loop when T1 committed; T1's capture was
# in the delta with a pgpm_seq below the batch's highest), but nothing re-checks that those witnesses
# would still let the file fail if the fix they guard were removed. Pointing the same file at a
# mutant is what checks that, every CI run, instead of once by hand in a commit message (#497).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   regrain_reconcile_delete_by_watermark -- the tick's final delete consumes every eligible delta row
#                                            at or below the batch's highest pgpm_seq, under its own
#                                            later snapshot, instead of exactly the rows the apply
#                                            statements addressed: pre-#497 behaviour at the one
#                                            statement where the loss happened. A capture that
#                                            committed mid-tick is deleted unapplied, and tests/124
#                                            sees id 150000 revert to 'orig' through the swap.
#
# Usage: regrain_reconcile_snapshot.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap, dblink and pg_prove, all of which it has).
# RECONCILE_SNAPSHOT_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${RECONCILE_SNAPSHOT_TEST_FILE:-/repo/tests/124_regrain_reconcile_snapshot_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the reconcile consumes only the captured rows it applied" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the reconcile consumes only the captured rows it applied" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
