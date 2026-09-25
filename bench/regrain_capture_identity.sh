#!/usr/bin/env bash
# Run tests/124_regrain_capture_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so this script adds nothing on correct code. What it adds is the standing
# proof that the file DISCRIMINATES. Its load-bearing assertions are negatives -- "the committed change is
# honoured after the swap", "the write into the source does not raise", "the app role can still write" --
# and a negative is equally satisfied by a run that never set up the condition it denies, which is the
# failure mode this repo has shipped six times. The file pins its setup with witnesses of its own (the
# derived name really changed, the delta really was minted with the old key, the role really lacked the
# privilege), but nothing re-checks that those witnesses would fail if the identity anchoring they guard
# were removed. Pointing the same file at a mutant is what checks that, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   regrain_capture_by_name  -- _regrain_capture_names ignores the oids pgpm.config recorded at prepare
#                               and derives the delta and function from the parent's CURRENT relname again,
#                               which is pre-#496 exactly: rename the parent mid-regrain and reconcile, the
#                               swap gate and the swap all look for a delta that does not exist, count 0
#                               pending, and swap the captured changes away with the source.
#   regrain_delta_reused     -- _regrain_capture_install keeps an existing delta (truncating it) instead of
#                               re-minting it from the current key, so a key column renamed between two
#                               regrains leaves the trigger inserting a column the delta does not have.
#   regrain_delta_ungranted  -- the delta is neither owned like the parent nor granted to its writers, so
#                               every non-owner role with DML on the parent gets 42501 on writes into the
#                               regraining child.
#
# Usage: regrain_capture_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). REGRAIN_CAPTURE_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${REGRAIN_CAPTURE_TEST_FILE:-/repo/tests/124_regrain_capture_identity_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "capture is anchored by oid, re-minted per regrain, granted" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "capture is anchored by oid, re-minted per regrain, granted" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
