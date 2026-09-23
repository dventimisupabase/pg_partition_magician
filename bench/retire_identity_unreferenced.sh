#!/usr/bin/env bash
# Run tests/103_retire_identity_unreferenced_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that its #428 assertions DISCRIMINATE. They are almost all negatives -- "the
# substitute was not dropped", "the partition pgpm meant is untouched", "the pgpm.part row stays" --
# and a negative is equally satisfied by a run that never set the substitution up, or by a table
# retire() could not have dropped anything on in the first place. The file pins both with liveness
# witnesses of its own (retiring_oid genuinely null so this is not #407's path, child_oid recorded,
# the substitute's different oid, and an untouched sibling that DOES retire in the same run), but
# nothing re-checks that those witnesses would fail if the guard they guard were removed.
#
# TWO mutations are required to fail against it, and they are not redundant -- each proves a
# different half of the file is load-bearing (bench/mutations/mutate.py):
#   retire_drop_child_oid_ignored      -- the check consults retiring_oid only, which is pre-#428
#                                         exactly. Breaks PART A; part B still passes.
#   retire_identity_coalesced_anchors  -- the plausible-but-wrong fix: coalesce(retiring_oid,
#                                         child_oid) instead of checking both. Part A still passes,
#                                         so only PART B catches it -- which is the whole reason
#                                         part B exists.
#
# Usage: retire_identity_unreferenced.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). No pg_cron is
# needed even though part B sets retiring_at/retiring_oid: the only cron call on the refusal path is
# pgpm._idle_detach_job, which swallows "no such schema" by design.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE=/repo/tests/103_retire_identity_unreferenced_test.sql
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "retire() refuses a substituted name on both anchors" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "retire() refuses a substituted name on both anchors" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
