#!/usr/bin/env bash
# Guard the in-place upgrade: re-running install.sql over an OLDER install must leave a database
# structurally identical to a fresh install, with its managed tables and their data intact.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT. install.sql IS the upgrade path for the install.sql channel: operators re-run the file
# over a live database. Fresh installs get every column from the `create table` bodies, but an EXISTING
# database only gets a new column if install.sql also carries an
# `alter table ... add column if not exists` line for it. Those 14 backfill lines are hand-maintained,
# and nothing enforces them. Add a column to a `create table` body, forget the backfill line, and every
# test in the suite still passes: the whole pgTAP suite installs FRESH, one database per file, so it
# never exercises an upgrade at all. The break lands only on an operator who already had pgpm
# installed, which is to say on the only people who are not evaluating it.
#
# WHY A SHELL HARNESS. Two separate databases (a fresh oracle and an upgraded one) and two runs of
# install.sql against one of them. pgTAP gives one database per file and wraps it in a transaction, and
# install.sql cannot be run from inside SQL at all.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   1. LIVENESS WITNESS, and the one this guard would be worthless without: after the degrade step, the
#      columns really are gone. Every later assertion is of the form "the upgrade restored X", and all
#      of them pass trivially against a degrade that silently did nothing (a renamed column, a typo in
#      the DROP list). This asserts the conditions for the defect were present before looking for it.
#   2. The pgpm catalog after the upgrade is IDENTICAL to a fresh install of the same code: every
#      column of every table and view, with its type. This is the assertion the mutation breaks.
#   3. Data survived BY IDENTITY, not by count. The fixture is asymmetric on purpose (3 inserted, 1
#      deleted, 2 surviving) so that a lost insert and a resurrected delete cannot cancel out into a
#      row count that still looks right.
#   4. Registration survived: the config row still names the same control column and step, so the
#      upgrade did not quietly reset the managed table's settings to defaults.
#   5. The upgrade was RECORDED: pgpm.installed holds two rows, the second one this version. Distinct
#      from 2: it separates "the file ran to the end" from "the schema happens to look right".
#   6. LIVENESS WITNESS: the machine still runs afterwards. maintain() on the table that existed BEFORE
#      the upgrade mints a new partition, named. A structurally perfect install that can no longer
#      obtain is not an upgrade anyone wants, and every assertion above it is satisfied by a database
#      that merely sits there.
#
# Usage: upgrade_in_place.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
FRESH="${DB}_fresh"
fail=0

q()  { docker exec "$C" psql -U postgres -d "$1" -qtA -c "$2"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$1" -qtA -v ON_ERROR_STOP=1 -c "$2"; }
install_into() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
                   psql -U postgres -q -d "$1" -v ON_ERROR_STOP=1 -f "$INSTALL"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The columns an older install lacks: every column install.sql backfills with `add column if not
# exists`. Hardcoded rather than parsed out of install.sql on purpose. Deriving it from the backfill
# lines would make the guard circular, since the mutation works by DELETING one of those lines: the
# derived list would lose the same entry, the degrade would not drop it, and the guard would pass
# against its own defect. The precondition below is what keeps a hardcoded list from rotting.
DEGRADE_COLS="
pgpm.config:obtain_retry_after
pgpm.config:regrain_batch
pgpm.config:regrain_max_blocks
pgpm.config:regrain_to
pgpm.config:regrain_cursor
pgpm.config:retain_batch
pgpm.config:archive_fn
pgpm.config:archive_byte_budget
pgpm.config:archive_probe_sample
pgpm.part:attached
pgpm.part:retiring_at
pgpm.dropped_fk:restored_at
pgpm.dropped_fk:validated_at
pgpm.dropped_fk:validate_retry_after
"
N_DEGRADE=$(echo "$DEGRADE_COLS" | grep -c ':')

# Every column of every table AND view in schema pgpm, with its type. Views are included because a
# DROP COLUMN ... CASCADE below takes pgpm.partitions with it, so "the view came back" is part of the
# claim.
CATALOG_SQL="select md5(string_agg(table_name||'.'||column_name||':'||data_type, ',' order by table_name, column_name))
             from information_schema.columns where table_schema = 'pgpm'"

# ---------------------------------------------------------------------------- fresh oracle
docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $FRESH" >/dev/null 2>&1
if ! install_into "$FRESH" >/tmp/up_fresh.log 2>&1; then
  echo "FAIL  the fresh oracle install did not complete"; sed 's/^/      /' /tmp/up_fresh.log; exit 1
fi
ORACLE=$(q "$FRESH" "$CATALOG_SQL")

# PRECONDITION: every column this guard intends to drop must exist in a fresh install. If the product
# drops one for real, this list is stale and the guard is quietly testing less than it claims. Fail
# loudly instead, exactly as bench/mutations/mutate.py refuses a pattern whose site count is off.
present=$(echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  q "$FRESH" "select 1 from information_schema.columns
               where table_schema='pgpm' and table_name='${t#pgpm.}' and column_name='$c'"
done | grep -c 1)
check "precondition: all degrade-list columns exist when fresh" "$present" "$N_DEGRADE"
if [ "$present" != "$N_DEGRADE" ]; then
  echo "      the DEGRADE_COLS list is stale; fix it before trusting anything below"; exit 1
fi

# ---------------------------------------------------------------------------- an older install, with state
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! install_into "$DB" >/tmp/up_old.log 2>&1; then
  echo "FAIL  the initial install did not complete"; sed 's/^/      /' /tmp/up_old.log; exit 1
fi

# A managed table with real rows, created BEFORE the upgrade. Asymmetric: 3 in, 1 out, so a lost
# insert and a resurrected delete cannot cancel into a plausible count.
# An ID-kind table, not a time one, and the choice is load-bearing for assertion 6. obtain measures a
# time table against the CLOCK, so nothing the harness inserts can give it work to do; for an id table
# the frontier is max(control), which the harness can move on purpose.
run "$DB" "create table public.up_t (
             id bigint not null,
             body text,
             primary key (id))" >/dev/null
run "$DB" "insert into public.up_t (id, body) values (10, 'keep-a'), (20, 'doomed'), (30, 'keep-b')" >/dev/null
run "$DB" "delete from public.up_t where body = 'doomed'" >/dev/null
run "$DB" "call pgpm.transmute('public.up_t', 'id', 1000::bigint, p_obtain => 1)" >/dev/null
run "$DB" "select pgpm.resume('public.up_t')" >/dev/null
run "$DB" "call pgpm.maintain('public.up_t')" >/dev/null

BODIES_BEFORE=$(q "$DB" "select string_agg(body, ',' order by body) from public.up_t")
CONFIG_BEFORE=$(q "$DB" "select control_column||'/'||partition_step from pgpm.config
                          where parent_table = 'public.up_t'::regclass")
CHILDREN_BEFORE=$(q "$DB" "select string_agg(child_name, ',' order by child_name) from pgpm.part
                            where parent_table = 'public.up_t'::regclass")

# ---------------------------------------------------------------------------- degrade to an older shape
# CASCADE because pgpm.partitions selects pgpm.part.attached; install.sql recreates the view.
echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  docker exec "$C" psql -U postgres -d "$DB" -qtA \
    -c "alter table $t drop column if exists $c cascade" >/dev/null 2>&1
done

# ASSERTION 1, the liveness witness. Everything below asserts the upgrade put something back; all of it
# passes against a degrade that did nothing at all.
still=$(echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  q "$DB" "select 1 from information_schema.columns
            where table_schema='pgpm' and table_name='${t#pgpm.}' and column_name='$c'"
done | grep -c 1)
check "the degrade really removed all $N_DEGRADE columns" "$still" "0"

# ---------------------------------------------------------------------------- the upgrade
if ! install_into "$DB" >/tmp/up_upgrade.log 2>&1; then
  echo "FAIL  the in-place upgrade did not complete"; sed 's/^/      /' /tmp/up_upgrade.log; fail=1
fi

check "the pgpm catalog matches a fresh install exactly" "$(q "$DB" "$CATALOG_SQL")" "$ORACLE"
check "rows survived, by identity"                       "$(q "$DB" "select string_agg(body, ',' order by body) from public.up_t")" "$BODIES_BEFORE"
check "registration survived (control column / step)"    "$(q "$DB" "select control_column||'/'||partition_step from pgpm.config where parent_table = 'public.up_t'::regclass")" "$CONFIG_BEFORE"
check "the upgrade run was recorded"                     "$(q "$DB" "select count(*)||'/'||max(version) from pgpm.installed")" "2/$(q "$FRESH" "select pgpm.version()")"

# ASSERTION 6, liveness. The pre-existing managed table must still be maintainable. Move the frontier
# to the top of the covered range so the next tick has real work: one id below the last bound, since
# `hi` is exclusive. It cannot be moved PAST that bound -- with no DEFAULT partition (#288) an insert
# beyond the last one is rejected rather than extending the grid, so the frontier is always inside it.
FRONTIER=$(q "$DB" "select max(hi)::bigint - 1 from pgpm.part where parent_table = 'public.up_t'::regclass")
run "$DB" "insert into public.up_t (id, body) values ($FRONTIER, 'post-upgrade')" >/dev/null
run "$DB" "call pgpm.maintain('public.up_t')" >/dev/null
CHILDREN_AFTER=$(q "$DB" "select string_agg(child_name, ',' order by child_name) from pgpm.part
                           where parent_table = 'public.up_t'::regclass")
new=$(comm -13 <(echo "$CHILDREN_BEFORE" | tr ',' '\n' | sort) \
               <(echo "$CHILDREN_AFTER"  | tr ',' '\n' | sort) | tr '\n' ' ')
if [ -n "${new// /}" ]; then
  printf 'PASS  %-58s %s\n' "maintain() still mints partitions after the upgrade" "new: ${new% }"
else
  printf 'FAIL  %-58s %s\n' "maintain() minted nothing after the upgrade" "children: $CHILDREN_AFTER"
  fail=1
fi

docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
exit "$fail"
