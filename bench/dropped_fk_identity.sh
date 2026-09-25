#!/usr/bin/env bash
# Run tests/124_dropped_fk_identity_test.sql against an ARBITRARY copy of pgpm_core/install.sql, then
# exercise the one piece of #498 a pgTAP file cannot: the install-time backfill of a record an earlier
# pgpm captured, which needs install.sql run a SECOND time over a database that already has state.
# bench/discriminate.sh points both halves at a mutant.
#
# WHY A WRAPPER EXISTS AT ALL. tests/124 is a plain pgTAP file and the default matrix already runs it on
# every version and channel, so the first half adds nothing on correct code. What it adds is the
# standing proof that the file DISCRIMINATES. Its contract assertions are negatives dressed as
# identities -- "the key is on the parent, not the monolith", "nothing references the decoy", "the
# orphan is refused" -- and every one of them is equally satisfied by a run in which the key was never
# restored at all, which is the failure mode this repo has shipped six times. The file pins its setup
# with liveness witnesses (the restore reported one key and logged exactly restore_incoming_fk, the
# forward partition the orphan routes to exists, the restoring session really has the default
# search_path), but nothing re-checks that those witnesses would fail if the anchoring they guard were
# removed. Pointing the same file at a mutant is what checks that, every CI run.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site of the fix:
#   dropped_fk_definition_session_search_path  -- the cutover captures pg_get_constraintdef() in the
#                                                 transmuting session again: unqualified when that
#                                                 session's search_path can see the parent, so the
#                                                 restore lands on whatever the name means THERE
#   dropped_fk_referencer_stays_on_monolith    -- the cutover no longer moves the records in which the
#                                                 converted table is the referencer onto its parent: a
#                                                 self-referential key (F5-02) and a key preserved against
#                                                 a table converted later (F5-07) both stay on the oid the
#                                                 rename turns into the monolith child
#   dropped_fk_definition_no_backfill          -- install.sql no longer rewrites a legacy unqualified
#                                                 record, which only the second half here can see
#
# Usage: dropped_fk_identity.sh <container> <db> [install.sql]
# Runs on the plain core image (it needs pgtap and pg_prove, both of which it has). DROPPED_FK_TEST_FILE
# overrides the test file's path inside the container, for running from a worktree that is mounted
# somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${DROPPED_FK_TEST_FILE:-/repo/tests/124_dropped_fk_identity_test.sql}"
UP="${DB}_up"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }
qa() { docker exec "$C" psql -U postgres -d "$UP" -qtA -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# ------------------------------------------------------------------ half 1: the pgTAP file, against $INSTALL
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
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # pg_prove's exit status covers "fewer assertions ran than the plan promised". What it cannot tell
  # apart from a real failure is a run that never reached the database, and discriminate.sh reads a
  # non-zero exit as "the guard caught the defect", so the count is asserted separately.
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "dropped_fk records anchor the key by identity, from any session" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "dropped_fk records anchor the key by identity, from any session" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1

# ------------------------------------------------------------------ half 2: the upgrade backfill of a legacy record
# A record captured by a pre-#498 pgpm reads `REFERENCES parent(id)`: the referenced table unqualified
# because the transmuting session could see it. Forge exactly that on a real record, then re-run
# $INSTALL over the database (the in-place upgrade path), and require the text to come back
# schema-qualified. The decoy public.parent is what makes a missing backfill a WRONG-TABLE result rather
# than an error: the restoring session's default search_path resolves the unqualified name to it.
q -q -c "drop database if exists $UP" >/dev/null 2>&1
q -q -c "create database $UP" >/dev/null 2>&1
if ! q -d "$UP" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed (upgrade half)" "$INSTALL"
  fail=1
else
  qa "create schema bf;
      create table bf.parent (id bigint primary key);
      create table bf.child (id bigint primary key, p_id bigint references bf.parent (id));
      create table public.parent (id bigint primary key);
      insert into bf.parent values (1); insert into bf.child values (1, 1);" >/dev/null
  qa "call pgpm.transmute('bf.parent', 'id', 1000::bigint, p_incoming_fks => 'preserve', p_paused => false)" >/dev/null
  qa "update pgpm.dropped_fk set definition = replace(definition, ' REFERENCES bf.parent(', ' REFERENCES parent(')
       where parent_table = 'bf.parent'::regclass" >/dev/null
  # LIVENESS: the legacy shape really is in place before the upgrade looks for it.
  check "the forged record reads as a pre-#498 capture would" \
        "$(qa "select definition from pgpm.dropped_fk where parent_table = 'bf.parent'::regclass")" \
        "FOREIGN KEY (p_id) REFERENCES parent(id)"
  if ! q -d "$UP" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-58s\n' "the in-place upgrade completed"; fail=1
  fi
  check "the upgrade rewrote the legacy record schema-qualified" \
        "$(qa "select definition from pgpm.dropped_fk where parent_table = 'bf.parent'::regclass")" \
        "FOREIGN KEY (p_id) REFERENCES bf.parent(id)"
  check "LIVENESS: the restore re-added one key from it" \
        "$(qa "select pgpm.restore_incoming_fks('bf.parent')")" "1"
  check "and that key references bf.parent, not the decoy public.parent" \
        "$(qa "select c.confrelid::regclass::text from pg_constraint c
                where c.conrelid = 'bf.child'::regclass and c.conname = 'child_p_id_fkey' and c.contype = 'f'")" \
        "bf.parent"
fi
q -q -c "drop database if exists $UP" >/dev/null 2>&1
exit "$fail"
