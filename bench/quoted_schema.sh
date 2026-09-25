#!/usr/bin/env bash
# Run tests/124_quoted_schema_test.sql against an ARBITRARY copy of pgpm_core/install.sql, so
# bench/discriminate.sh can point it at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. That file is a plain pgTAP file and the default matrix already runs it
# on every version and channel, so this script adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its load-bearing assertions are negatives -- "no archive
# tick failed", "no regrain tick or janitor pass failed", "the twin's write block is not ours" -- and a
# negative is equally satisfied by a run that never reached the code it denies, which is the failure
# mode this repo has shipped six times. Here that risk is concrete rather than hypothetical: the defect
# (#512) only surfaced when a trigger row of exactly the right name met the cast, so a fixture with no
# same-named child under a trigger anywhere stayed quiet on the BROKEN code. The file pins that
# condition with witnesses of its own (the control archived and retired in the same ticks, a same-named
# child in a lower-case schema carried the capture trigger throughout, the twin really is blocked), but
# nothing re-checks that those witnesses would fail if the OID comparison they guard were undone.
# Pointing the same file at a mutant is what checks that, every CI run, instead of once by hand.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   schema_name_regnamespace_cast -- _is_write_blocked and _regrain_capture_active select the parent's
#                                    schema by NAME and cast it back with `v_nsp::regnamespace`, which
#                                    is pre-#512 behaviour exactly: a schema that needs quoting
#                                    ("Sales") downcases, so the lookup raises (skip_archive every
#                                    tick, skip_regrain, skip_regrain_capture) or, once a lower-case
#                                    twin exists, answers for the twin's same-named child
#
# Usage: quoted_schema.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has).
# QUOTED_SCHEMA_TEST_FILE overrides the test file's path inside the container, for running from a
# worktree that is mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${QUOTED_SCHEMA_TEST_FILE:-/repo/tests/124_quoted_schema_test.sql}"
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
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "a schema that needs quoting archives, retires and regrains" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "a schema that needs quoting archives, retires and regrains" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
