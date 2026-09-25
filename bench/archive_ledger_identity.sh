#!/usr/bin/env bash
# Run tests/125_archive_ledger_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its assertions are negatives and bounded claims -- "no
# archive tick failed", "every fine child was retired within 40 ticks", "nothing is left under the old
# name" -- and every one of them is equally satisfied by a run in which no chunk was ever recorded
# before the regrain or the rename, which is exactly the setup tests/74 has and the reason it stayed
# green over this defect. The file pins its setup with liveness witnesses (a chunk really sits in the
# ledger under the old name, it really ends inside the data, the strategy really was handed that
# prefix), but nothing re-checks that those witnesses would fail if the mechanism they guard were
# removed. Pointing the same file at a mutant is what checks that, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per mechanism the fix
# for #511 added, so that a later refactor that quietly drops one of them is named:
#   archive_ledger_no_orphan_sweep     -- _archive_step no longer discards coverage recorded under a
#                                         name that is not a tracked partition; the pre-#511 rename
#                                         procedure wedges on archive_ledger_pkey again (case B)
#   regrain_swap_keeps_source_ledger   -- the swap drops the source but leaves its chunks in the ledger;
#                                         case A's post-swap assertions see them (the tick's own discard
#                                         then clears them, so the run still completes: only the direct
#                                         assertions name this mutant)
#   regrain_rename_orphans_ledger      -- the #266 transitional rename updates pgpm.part.child_name but
#                                         not the ledger, leaving the source's coverage under a name
#                                         nothing tracks, which the first fine child then takes (case D)
#
# Usage: archive_ledger_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# ARCHIVE_LEDGER_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${ARCHIVE_LEDGER_TEST_FILE:-/repo/tests/125_archive_ledger_identity_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "archive coverage follows the partition, not a stale name" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "archive coverage follows the partition, not a stale name" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
