#!/usr/bin/env bash
# Run tests/125_archive_chunk_ties_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. The defect it guards against (#513) is a stall with no
# symptom: the chunk picker returned no chunk, _archive_step moved on without a log row, and the
# partition simply stayed. Almost every assertion in the file is therefore about something that must
# have HAPPENED (a ledger row past the burst, a retain_drop, a relation gone), and the one negative in
# it, "nothing was deferred or refused", is satisfied by the defect exactly as well as by the fix. The
# file pins its setup with liveness witnesses (the burst really decodes to one native unit, the budget
# really holds fewer rows than the burst, the first chunk really stopped at the burst's edge), but
# nothing re-checks that the assertions after them would fail if the fix were removed. Pointing the same
# file at a mutant is what checks that, every CI run, instead of once by hand in a commit message.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_chunk_native_ties  -- the extension past the encoding's unit removed, so a next distinct
#                                 column value that decodes to the chunk's own lo makes the picker return
#                                 nothing, which is pre-#513 behaviour exactly: tests/125's ledger stays
#                                 at its first chunk and the 2020 child is never retired
#
# Usage: archive_chunk_ties.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). ARCHIVE_TIES_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${ARCHIVE_TIES_TEST_FILE:-/repo/tests/125_archive_chunk_ties_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a run of ties on the native grid travels whole and archiving goes on" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a run of ties on the native grid travels whole and archiving goes on" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
