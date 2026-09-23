#!/usr/bin/env bash
# Run tests/104_write_block_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that its #429 assertions DISCRIMINATE. Part A's are negatives -- "the substitute did
# NOT get a trigger", "pgpm issued no DDL against it" -- and a negative is equally satisfied by a
# write-block pass that installed nothing anywhere, which is the failure mode this repo has shipped
# six times. The file pins that with liveness witnesses of its own (the recorded child_oid, the
# substitute's different oid, the substitute carrying no triggers going in, and an untouched sibling
# that IS blocked by the same pass), but nothing re-checks that those witnesses would fail if the
# guard they guard were removed.
#
# THREE mutations are required to fail against it, one per part, and none is redundant -- each is a
# different plausible way to get this wrong:
#   write_block_unanchored_name         -- the identity check deleted, so CREATE TRIGGER lands on
#                                          whatever answers to the name. Pre-#429 behaviour exactly.
#                                          Breaks PART A.
#   write_block_remove_anchored         -- the symmetrical-looking mistake #429 declined to make:
#                                          anchoring _remove_write_block too, which strands a trigger
#                                          a pre-#429 version already put on a substituted relation
#                                          and leaves it read-only with no pgpm-side recovery.
#                                          Breaks PART B only.
#   write_block_refuses_missing_relation -- the other tempting consistency fix: firing on a name that
#                                          resolves to nothing, the way retire() and _archive_step
#                                          do. That misreports a dropped partition as a substitution
#                                          AND silently retires tests/94's loop-isolation coverage,
#                                          whose poison would stop raising. Breaks PART C only.
#
# Usage: write_block_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE=/repo/tests/104_write_block_identity_test.sql
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the write block is installed only on the right relation" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the write block is installed only on the right relation" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
