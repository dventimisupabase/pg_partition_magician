#!/usr/bin/env bash
# Run tests/129_set_archive_fn_return_type_test.sql against an ARBITRARY copy of pgpm_core/install.sql,
# so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its central assertions are negatives -- "the mis-typed
# strategy was refused", "config.archive_fn is unchanged", "the mis-typed strategy was never called",
# "no partition was dropped on a ledger row it produced" -- and a negative is equally satisfied by a
# run in which the mis-typed candidate never got past the regprocedure cast, or in which the tick never
# reached the archive step at all. The file pins its own setup with liveness witnesses (the cast alone
# accepts the candidate; a well-typed twin with the same argument list is accepted; the tick called
# the well-typed strategy for the exact chunk and dropped the partition after a real archive), but
# nothing re-checks that those witnesses would still let the file fail if the check they guard were
# removed. Pointing the same file at a mutant is what checks that, every CI run, instead of once by
# hand in a commit message (#517).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   set_archive_fn_no_return_type_check -- set_archive_fn back to its pre-#517 body: the regprocedure
#                                          cast alone, which resolves the argument list and nothing
#                                          else, so a `returns text` strategy is installed, the next
#                                          tick maps its one column onto covered_hi, a strategy echoing
#                                          p_hi passes the contract check, and the partition is dropped
#                                          on a ledger row with rows_archived null. tests/129 fails
#                                          against this on the refusals, on the unchanged switch, on
#                                          the strategy that was called, and on the ledger row.
#
# Usage: set_archive_fn_return_type.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# SET_ARCHIVE_FN_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${SET_ARCHIVE_FN_TEST_FILE:-/repo/tests/129_set_archive_fn_return_type_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "set_archive_fn refuses a strategy of the wrong return type" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "set_archive_fn refuses a strategy of the wrong return type" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
