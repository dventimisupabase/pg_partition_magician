#!/usr/bin/env bash
# Run tests/125_untransmute_residue_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its load-bearing assertions are negatives -- "the restored
# table carries no trigger", "the fine copy is gone", "the capture function is gone" -- and a negative is
# equally satisfied by a run in which there was never a block or a regrain to strip, which is the failure
# mode this repo has shipped six times. The file pins its setup with liveness witnesses of its own (the
# monolith really carries pgpm_write_block and really rejects a write; the capture trigger really sits on
# the monolith and really lands an update in the delta), but nothing re-checks that those witnesses would
# still fail if the stripping they guard were removed. Pointing the same file at a mutant is what checks
# that, every CI run, instead of once by hand in a commit message.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   untransmute_keeps_write_block      -- untransmute no longer lifts pgpm_write_block from the monolith,
#                                         which is pre-#508 behaviour exactly: a retention-blocked table
#                                         comes back unmanaged and permanently read-only
#   untransmute_keeps_regrain_capture  -- untransmute no longer abandons an in-flight regrain, so the
#                                         capture trigger rides the restored table and its own
#                                         `drop function` dies on the dependency, as before #508
#
# Usage: untransmute_residue.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# UNTRANSMUTE_RESIDUE_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${UNTRANSMUTE_RESIDUE_TEST_FILE:-/repo/tests/125_untransmute_residue_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "untransmute hands back a monolith with none of pgpm's apparatus on it" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "untransmute hands back a monolith with none of pgpm's apparatus on it" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
