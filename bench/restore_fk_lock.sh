#!/usr/bin/env bash
# Guard restore_incoming_fks against blocking the MANAGED PARENT for O(referencing table) (issue #265).
# Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# Re-adding a preserve-managed FK is ADD CONSTRAINT ... NOT VALID then VALIDATE, which is the right recipe
# and the standard way to keep a validation scan off a blocking lock. It bought nothing here, because both
# statements shared one transaction: the ADD takes SHARE ROW EXCLUSIVE on BOTH tables and that lock was
# still held while the VALIDATE scanned.
#
# SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so this blocked INSERT/UPDATE/DELETE on the referencing
# table AND on the managed parent -- the table pgpm exists to keep online. Measured at 224 ms against 4M
# referencing rows, and linear: roughly 66 ms per million, so a 200M-row referencing table is about 13 s of
# blocked writes on the parent, once per drain campaign, forever.
#
# The assertion is the consequence an operator sees: a plain INSERT into the PARENT, with a lock_timeout
# far shorter than the scan, must never time out while a restore runs. 50 ms against a ~224 ms pre-fix
# hold and a millisecond-scale post-fix one, so neither verdict rides on a close call.
#
# Usage: restore_fk_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to prove
# this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
PARENT_ROWS=${PARENT_ROWS:-200000}
REF_ROWS=${REF_ROWS:-4000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.messages (id bigint primary key, body text)" >/dev/null
q "insert into public.messages select g, 'x' from generate_series(1, $PARENT_ROWS) g" >/dev/null
q "create table public.reactions (id bigint primary key,
     message_id bigint not null references public.messages(id), v text)" >/dev/null
q "insert into public.reactions select g, ((g % $PARENT_ROWS) + 1), 'r'
     from generate_series(1, $REF_ROWS) g" >/dev/null
# 'preserve' drops the incoming FK at conversion and records it, so restore_incoming_fks has work to do.
# Everything stays in the monolith and the DEFAULT is empty, so its quiescence gates are already satisfied.
q "call pgpm.transmute('public.messages','id', $PARENT_ROWS::bigint,
     p_incoming_fks => 'preserve', p_paused => false)" >/dev/null
q "vacuum analyze public.messages" >/dev/null
q "vacuum analyze public.reactions" >/dev/null
q "create table public.probe (attempts int, timeouts int, saw boolean)" >/dev/null
q "create table public.done (x int)" >/dev/null

docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "select pgpm.restore_incoming_fks('public.messages')" \
  -c "insert into public.done values (1)" >/tmp/rfk_bg.log 2>&1 &
BG=$!

# COMMIT after every attempt. Locks are held to transaction end and a DO block is ONE transaction, so a
# probe that just loops pins its own lock on the parent and blocks the very ADD it is trying to observe,
# which makes the run prove nothing. Learned on bench/maintain_lock.sh.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; t int := 0; saw boolean := false;
begin
  for i in 1 .. 2000000 loop
    exit when exists(select 1 from pg_stat_activity
                      where datname = current_database() and pid <> pg_backend_pid()
                        and query like '%restore_incoming_fks%' and state = 'active');
    commit;
  end loop;
  saw := true;
  while not exists(select 1 from public.done) loop
    begin
      set local lock_timeout = '50ms';
      insert into public.messages (id, body) values ($PARENT_ROWS + n + 1, 'live write');
    exception when others then t := t + 1; end;
    n := n + 1;
    commit;
  end loop;
  insert into public.probe values (n, t, saw);
end \$p\$;" >/dev/null 2>&1
wait $BG

check "the probe overlapped a running restore"    "$(q "select saw::text from public.probe")"          "true"
check "at least one write landed inside it"       "$(q "select (attempts > 0)::text from public.probe")" "true"
check "writes to the MANAGED PARENT are not blocked" "$(q "select timeouts::text from public.probe")"   "0"
# conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets one
# pg_constraint row per partition of the referenced side, so an unfiltered count reports 3 here, not 1.
check "the FK was actually re-added"              "$(q "select count(*)::text from pg_constraint
       where conrelid = 'public.reactions'::regclass and contype = 'f' and conparentid = 0")" "1"

exit "$fail"
