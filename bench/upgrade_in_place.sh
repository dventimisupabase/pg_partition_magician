#!/usr/bin/env bash
# Guard the in-place upgrade: re-running install.sql over an OLDER install must leave a database
# structurally identical to a fresh install, with its managed tables and their data intact.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT. install.sql IS the upgrade path for the install.sql channel: operators re-run the file
# over a live database. Fresh installs get every column from the `create table` bodies, but an EXISTING
# database only gets a new column if install.sql also carries an
# `alter table ... add column if not exists` line for it. Those backfill lines are hand-maintained,
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
#      And, separately and BY NAME, every routine in schema pgpm: name, identity arguments, kind and
#      result type. `create or replace` across a changed argument list creates a second overload
#      rather than replacing the first (issue #441), and when the new argument has a default the old
#      call shape matches both and fails with "is not unique". This origin, a degraded FRESH install,
#      can never carry an old signature to leave behind, so this comparison cannot catch a missed drop
#      line here; bench/upgrade_from_release.sh upgrades a real released artifact for that. It is
#      still made here so that any routine-level drift an upgrade does leave is a named difference in
#      this guard's output rather than something folded silently into the column hash.
#   3. A backfilled column's VALUE, where restoring the column empty is not good enough (issue #421).
#      pgpm.part.child_oid is what the archive step checks a candidate's name against, and a null one
#      reads as unanchored -- so an upgrade that recreated the column and populated nothing would
#      leave every partition an existing install already had permanently unprotected, with assertion
#      2 perfectly green. Checked BY IDENTITY: each row's child_oid must be the oid its OWN name
#      resolves to, so a backfill writing one plausible oid everywhere fails too.
#   4. Data survived BY IDENTITY, not by count. The fixture is asymmetric on purpose (3 inserted, 1
#      deleted, 2 surviving) so that a lost insert and a resurrected delete cannot cancel out into a
#      row count that still looks right.
#   5. Registration survived: the config row still names the same control column and step, so the
#      upgrade did not quietly reset the managed table's settings to defaults.
#   6. The upgrade was RECORDED: pgpm.installed holds two rows, the second one this version. Distinct
#      from 2: it separates "the file ran to the end" from "the schema happens to look right".
#   7. LIVENESS WITNESS: the machine still runs afterwards. maintain_obtain() (issue #347 split obtain
#      out of maintain()/maintain_all(), so this is now the call that mints partitions) on the table
#      that existed BEFORE the upgrade mints a new partition, named. A structurally perfect install
#      that can no longer obtain is not an upgrade anyone wants, and every assertion above it is
#      satisfied by a database that merely sits there.
#
# AND TWO PRECONDITIONS ON DEGRADE_COLS ITSELF, before any of that, running in OPPOSITE directions.
# The list is hardcoded and has to be (see the comment on it below), so something has to stop it
# rotting, and one direction does not: "every listed column exists in a fresh install" catches the
# list naming a column the product has DROPPED, while "every backfilled column is in the list"
# catches the product GAINING one the list forgot. Drift only ever goes the second way -- every new
# column is an opportunity to forget -- and for a long time only the first check existed, which is
# how the list came to sit at 15 entries against 25 backfill lines with nothing reporting anything
# (issue #417). Ten backfill lines were exercised by nobody, including the two that carry #405's
# claim that a crashed transmute stays reapable.
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
# against its own defect. The two preconditions below are what keep a hardcoded list from rotting.
# In install.sql's own order, so a new backfill line has an obvious place to go.
DEGRADE_COLS="
pgpm.config:partition_tz
pgpm.config:obtain_retry_after
pgpm.config:text_time_prefix
pgpm.config:text_time_width
pgpm.config:text_time_radix
pgpm.config:text_time_unit
pgpm.config:text_time_alphabet
pgpm.config:text_time_discard_bits
pgpm.config:text_time_epoch
pgpm.config:regrain_batch
pgpm.config:regrain_max_blocks
pgpm.config:regrain_to
pgpm.config:regrain_cursor
pgpm.config:regrain_delta_oid
pgpm.config:regrain_capture_fn_oid
pgpm.config:retain_batch
pgpm.config:archive_fn
pgpm.config:archive_byte_budget
pgpm.config:archive_probe_sample
pgpm.config:archive_batch
pgpm.part:attached
pgpm.part:retiring_at
pgpm.part:retiring_oid
pgpm.part:child_oid
pgpm.transmute_inflight:owner_pid
pgpm.transmute_inflight:owner_backend_start
pgpm.transmute_inflight:partition_tz
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

# Every routine in schema pgpm, one line each: name, identity arguments, kind (f/p) and result type. Kept
# as a LIST rather than a hash so a difference is reported by name (a stale overload reads as
# `schedule(p_every text) f bigint`, only after upgrade). prokind is "char", which `||` will not take
# without the cast; the cast is not decoration, an uncast version of this query errors and returns
# nothing, and nothing-equals-nothing is a pass.
ROUTINES_SQL="select proname||'('||pg_get_function_identity_arguments(oid)||') '||prokind::text||' '||coalesce(pg_get_function_result(oid), '')
              from pg_proc where pronamespace = 'pgpm'::regnamespace"
routines() { q "$1" "$ROUTINES_SQL" | LC_ALL=C sort; }

# ---------------------------------------------------------------------------- fresh oracle
docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $FRESH" >/dev/null 2>&1
if ! install_into "$FRESH" >/tmp/up_fresh.log 2>&1; then
  echo "FAIL  the fresh oracle install did not complete"; sed 's/^/      /' /tmp/up_fresh.log; exit 1
fi
ORACLE=$(q "$FRESH" "$CATALOG_SQL")
routines "$FRESH" > /tmp/up_fresh_routines.txt
# The routine oracle must have read SOMETHING, or the identity comparison below is empty-equals-empty.
N_ROUTINES=$(grep -c . /tmp/up_fresh_routines.txt)
if [ "$N_ROUTINES" -lt 1 ]; then
  echo "FAIL  the fresh oracle lists no routines at all: the routine comparison would compare nothing"; exit 1
fi

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

# PRECONDITION, the other direction (issue #417). The one above catches the list naming a column the
# product has DROPPED. It cannot catch the product GAINING a backfilled column the list does not
# name -- and that is the direction drift actually goes, so for a long time it reported nothing while
# ten of twenty-five backfill lines went unexercised. So: read the backfill lines out of the install
# file that is about to be run, and fail when one of them is not in the list.
#
# This does NOT make the guard circular, and the asymmetry is exactly why. The mutation deletes a
# backfill line, and a missing backfill LINE is not a missing LIST entry: this check still passes
# under the mutant, the degrade still drops the column, and the catalog-hash assertion below is
# still what fails. The check that would be circular is the converse -- "every list entry has a
# backfill line" -- which would fail under the mutant for a reason that is not the defect, and it is
# deliberately absent.
#
# Parse the file being INSTALLED, not the repo's copy, so this describes the run that is happening.
BACKFILL_RAW=$(docker exec "$C" grep -i 'add column if not exists' "$INSTALL" | grep -v '^[[:space:]]*--')
N_LOOSE=$(printf '%s\n' "$BACKFILL_RAW" | grep -c .)
if [ "$N_LOOSE" -lt 1 ]; then
  echo "FAIL  found no backfill lines at all in $INSTALL: this precondition is reading nothing"; exit 1
fi
# The loose match above is case-insensitive and this strict parse is not, on purpose: a backfill line
# written in a style this regex cannot read shows up as a count mismatch and fails loudly, rather than
# as a line the check silently does not cover. Comparing the two counts is the liveness witness for
# the parse -- without it, a regex that had quietly stopped matching would report nothing unlisted.
BACKFILLED=$(printf '%s\n' "$BACKFILL_RAW" \
  | sed -nE 's/^[[:space:]]*alter table ([a-z_]+\.[a-z_]+) add column if not exists ([a-z_]+).*/\1:\2/p')
N_BACKFILL=$(printf '%s\n' "$BACKFILLED" | grep -c ':')
check "precondition: every backfill line parsed" "$N_BACKFILL" "$N_LOOSE"
if [ "$N_BACKFILL" != "$N_LOOSE" ]; then
  echo "      a backfill line this parser cannot read is a column it cannot check for; fix the regex"; exit 1
fi

unlisted=$(printf '%s\n' "$BACKFILLED" | grep ':' | while read -r col; do
  printf '%s\n' "$DEGRADE_COLS" | grep -qxF "$col" || printf '%s ' "$col"
done)
unlisted="${unlisted% }"
check "precondition: every backfilled column is degraded" "${unlisted:-none}" "none"
if [ -n "$unlisted" ]; then
  echo "      add them to DEGRADE_COLS; their backfill lines are exercised by nothing until you do"; exit 1
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
run "$DB" "call pgpm.maintain_obtain('public.up_t')" >/dev/null
run "$DB" "call pgpm.maintain('public.up_t')" >/dev/null

# A regrain IN FLIGHT across the upgrade (#496). Before the two anchor columns existed, its capture relations
# were found by the parent's name alone; the upgrade must record their oids, or the rename hazard is back for
# exactly the regrain the operator had running. Move the frontier into the forward partition so the monolith
# freezes, then ONE tick: 'prepared' is the tick that mints the capture. Asserted, because everything the
# anchor assertion below says is also true of a run that never had a regrain in flight.
run "$DB" "insert into public.up_t (id, body) values (1500, 'freeze')" >/dev/null
MONO=$(q "$DB" "select child_name from pgpm.part where parent_table = 'public.up_t'::regclass and attached
                 order by lo::numeric limit 1")
check "LIVENESS: a regrain is in flight before the degrade" \
  "$(q "$DB" "select pgpm.regrain_step('public.up_t', '$MONO', '100', 50)")" "prepared"

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

# ASSERTION 2, the routine half (#441). Named differences, not a hash: `only after upgrade` is what a
# stale overload looks like, `only in fresh` what a routine the upgrade failed to create looks like.
routines "$DB" > /tmp/up_routines.txt
if cmp -s /tmp/up_fresh_routines.txt /tmp/up_routines.txt; then
  printf 'PASS  %-58s %s\n' "the pgpm routines match a fresh install exactly" "$N_ROUTINES routines"
else
  printf 'FAIL  %-58s\n' "the pgpm routines differ from a fresh install"
  comm -23 /tmp/up_fresh_routines.txt /tmp/up_routines.txt | sed 's/^/      only in fresh:      /'
  comm -13 /tmp/up_fresh_routines.txt /tmp/up_routines.txt | sed 's/^/      only after upgrade: /'
  fail=1
fi

# ASSERTION 3 (#421). Reported as anchored/total so "0 rows examined" cannot read as success: the
# expectation is built from the children this fixture actually had before the degrade, not from the
# same query that produces the answer.
NPARTS=$(echo "$CHILDREN_BEFORE" | tr ',' '\n' | grep -c .)
ANCHORED=$(q "$DB" "select count(*) filter (where p.child_oid is not null
                                              and p.child_oid = to_regclass(format('%I.%I', n.nspname, p.child_name))::oid)
                           || '/' || count(*)
                      from pgpm.part p
                      join pg_class c on c.oid = p.parent_table
                      join pg_namespace n on n.oid = c.relnamespace
                     where p.parent_table = 'public.up_t'::regclass")
check "the upgrade backfilled child_oid, to each child's own oid" "$ANCHORED" "$NPARTS/$NPARTS"
# ASSERTION 3b (#496), by identity: each anchor must be the relation its own derived name resolves to. A
# backfill that wrote nothing reads null/null, one that wrote a plausible oid somewhere else reads false.
check "the upgrade anchored the in-flight regrain's capture (delta/fn)" \
  "$(q "$DB" "select coalesce((regrain_delta_oid = to_regclass('public.up_t_pgpm_regrain_delta')::oid)::text, 'null')
                || '/' || coalesce((regrain_capture_fn_oid = to_regprocedure('public.up_t_pgpm_regrain_capture()')::oid)::text, 'null')
                from pgpm.config where parent_table = 'public.up_t'::regclass")" "true/true"
check "rows survived, by identity"                       "$(q "$DB" "select string_agg(body, ',' order by body) from public.up_t")" "$BODIES_BEFORE"
check "registration survived (control column / step)"    "$(q "$DB" "select control_column||'/'||partition_step from pgpm.config where parent_table = 'public.up_t'::regclass")" "$CONFIG_BEFORE"
check "the upgrade run was recorded"                     "$(q "$DB" "select count(*)||'/'||max(version) from pgpm.installed")" "2/$(q "$FRESH" "select pgpm.version()")"

# ASSERTION 7, liveness. The pre-existing managed table must still be maintainable. Move the frontier
# to the top of the covered range so the next tick has real work: one id below the last bound, since
# `hi` is exclusive. It cannot be moved PAST that bound -- with no DEFAULT partition (#288) an insert
# beyond the last one is rejected rather than extending the grid, so the frontier is always inside it.
FRONTIER=$(q "$DB" "select max(hi)::bigint - 1 from pgpm.part where parent_table = 'public.up_t'::regclass")
run "$DB" "insert into public.up_t (id, body) values ($FRONTIER, 'post-upgrade')" >/dev/null
run "$DB" "call pgpm.maintain_obtain('public.up_t')" >/dev/null
CHILDREN_AFTER=$(q "$DB" "select string_agg(child_name, ',' order by child_name) from pgpm.part
                           where parent_table = 'public.up_t'::regclass")
new=$(comm -13 <(echo "$CHILDREN_BEFORE" | tr ',' '\n' | sort) \
               <(echo "$CHILDREN_AFTER"  | tr ',' '\n' | sort) | tr '\n' ' ')
if [ -n "${new// /}" ]; then
  printf 'PASS  %-58s %s\n' "maintain_obtain() still mints partitions after the upgrade" "new: ${new% }"
else
  printf 'FAIL  %-58s %s\n' "maintain_obtain() minted nothing after the upgrade" "children: $CHILDREN_AFTER"
  fail=1
fi

docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
exit "$fail"
