#!/usr/bin/env bash
# Guard a maintenance tick against holding a data-coupled lock (issue #279). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# pgpm.obtain takes ACCESS EXCLUSIVE on the PARENT (CREATE TABLE ... PARTITION OF) and on the DEFAULT
# (ADD CONSTRAINT ... NOT VALID). Locks release at transaction end, so while a tick is one transaction
# those are held across everything that follows -- including the drain, whose duration is proportional to
# drain_batch. On the parent, that blocks readers too: the whole table stalls for the length of a drain
# batch, on every tick where obtain happens to create a partition.
#
# The assertion is the consequence an operator would actually see, not the lock mode: a plain SELECT
# against the parent, with a lock_timeout far shorter than the drain, must never time out during a tick.
# drain_batch is set so the pre-fix hold (~2.3 s) is over the reader's 1 s timeout by a wide margin while
# obtain's own window (~80 ms) is comfortably under it, so neither verdict rides on a close call.
#
# Usage: maintain_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
MONO=${MONO:-6000000}       # rows loaded before the conversion; the monolith covers them
TAIL=${TAIL:-3000000}       # rows written past the monolith, which land in the DEFAULT
BATCH=${BATCH:-1000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.ml (id bigint primary key, v text)" >/dev/null
q "insert into public.ml select g, repeat('x',60) from generate_series(1,$MONO) g" >/dev/null
q "call pgpm.transmute('public.ml','id', $MONO::bigint, p_paused => false)" >/dev/null
# Rows PAST the monolith pile up in the DEFAULT: they give obtain a non-empty default to scan and the
# drain a closed tail to work, which is what puts both in the same tick. The monolith's upper bound is
# read back rather than assumed -- transmute rounds it up to the next grid step, so it sits above the
# data, and rows written to a hardcoded MONO+1 would land inside the monolith and never reach the default.
HI=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ml'::regclass")
q "insert into public.ml select g, repeat('x',60) from generate_series($((HI+1)), $((HI+TAIL))) g" >/dev/null
q "vacuum analyze public.ml" >/dev/null
# A step well under the data range leaves a closed tail for the drain AND an empty future cell for obtain.
q "update pgpm.config set partition_step='1000000', obtain=1, drain_adaptive=false, drain_batch=$BATCH
     where parent_table='public.ml'::regclass" >/dev/null

q "create table public.probe (attempts int, timeouts int, saw_tick boolean)" >/dev/null
q "create table public.done (x int)" >/dev/null

docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "call pgpm.maintain_all()" -c "insert into public.done values (1)" >/tmp/ml_bg.log 2>&1 &
BG=$!

# Two things this probe has to get right, both learned by getting them wrong:
#
# 1. COMMIT after every read. AccessShareLock is held to transaction end and a DO block is ONE
#    transaction, so a probe that just loops on SELECT pins AccessShareLock for its whole run. obtain
#    then cannot get ACCESS EXCLUSIVE within its 200 ms lock_timeout and DEFERS -- the tick logs
#    obtain_skip and drain_skip, takes no strong lock at all, and the guard passes having tested nothing.
#
# 2. Do not read until obtain has had its chance. obtain fails fast by design, so a probe holding any
#    lock at the start of the tick suppresses the very step whose lock is under test. Wait for the tick,
#    give obtain a window, and only then start reading -- by which point a pre-fix run is in the drain
#    with ACCESS EXCLUSIVE still held from obtain, and a post-fix run has committed and released it.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; t int := 0; saw boolean := false;
begin
  for i in 1 .. 2000000 loop
    exit when exists(select 1 from pg_stat_activity
                      where datname = current_database() and pid <> pg_backend_pid()
                        and query like '%maintain_all%' and state = 'active');
    commit;
  end loop;
  saw := true;
  perform pg_sleep(0.5);            -- obtain is ~80 ms; the drain that follows is ~2.3 s
  commit;
  while not exists(select 1 from public.done) loop
    begin
      set local lock_timeout = '1s';
      perform 1 from public.ml limit 1;
    exception when others then t := t + 1; end;
    n := n + 1;
    commit;                         -- release AccessShareLock so the tick is never starved
  end loop;
  insert into public.probe values (n, t, saw);
end \$p\$;" >/dev/null 2>&1
wait $BG

check "the probe overlapped a running tick"     "$(q "select saw_tick::text from public.probe")" "true"
check "a concurrent reader is never locked out" "$(q "select timeouts::text from public.probe")"  "0"
check "at least one read landed inside the tick" \
      "$(q "select (attempts > 0)::text from public.probe")" "true"
# These two are what stop the guard passing vacuously. A tick starved of its locks logs obtain_skip and
# drain_skip, takes no ACCESS EXCLUSIVE, and would sail through the reader assertion having proved
# nothing -- so both steps must be shown to have done real work, and a *_skip must not count as work.
check "the tick did the work that takes the lock" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action = 'obtain'")" "true"
check "and drained in the same tick" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action in ('drain_move','drain_attach')")" "true"

exit "$fail"
