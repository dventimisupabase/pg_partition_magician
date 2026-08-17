#!/usr/bin/env bash
# Guard a maintenance tick against holding a data-coupled lock (issue #279). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# pgpm.obtain takes ACCESS EXCLUSIVE on the PARENT (CREATE TABLE ... PARTITION OF). Locks release at
# transaction end, so while a tick is one transaction that lock is held across everything that follows.
# On the parent it blocks readers too, so the whole table stalls for as long as the rest of the tick takes.
#
# The long step in a tick used to be the drain; #288 removed it and the DEFAULT with it, so the long step
# is now a REGRAIN copy microbatch. This guard drives a regrain rather than a drain: same shape, same
# assertion, and it protects the same five boundaries in maintain().
#
# The assertion is the consequence an operator would actually see, not the lock mode: a plain SELECT
# against the parent, with a lock_timeout far shorter than the regrain batch, must never time out during a
# tick. obtain's own window is ~1 ms (pure metadata now), far under the reader's 1 s timeout, so neither
# verdict rides on a close call.
#
# Usage: maintain_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
MONO=${MONO:-6000000}       # rows loaded before the conversion; the monolith covers them
BATCH=${BATCH:-2000000}
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
# Advance the frontier to the TOP of the grid so the next obtain has a partition to create. Without that
# the tick takes no ACCESS EXCLUSIVE at all and the guard would pass having observed nothing. The grid's
# ceiling is read back rather than assumed, since transmute now builds it during the cutover.
HI=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ml'::regclass")
q "insert into public.ml values ($((HI-1)), 'advances the frontier to the grid ceiling')" >/dev/null
q "vacuum analyze public.ml" >/dev/null
# Auto-regrain of the coarse monolith into fine children is the long step in a tick now. A small target
# step means many copy microbatches, so the tick is long enough to span if a boundary goes missing.
q "update pgpm.config set drain_batch=$BATCH where parent_table='public.ml'::regclass" >/dev/null
# Sub-range width chosen from measurement, not guessed: at 2,000,000 a copy tick runs 2.1-2.4 s, which
# comfortably outlasts the ~150 ms it takes the probe's own psql session to start. At 100k and at 500k the
# tick finished before the probe could read, and the guard reported nothing observed.
q "select pgpm.set_regrain('public.ml', '2000000')" >/dev/null

# One warm-up tick. A regrain's FIRST tick returns 'prepared': it installs change capture and copies
# nothing, so it takes ~26 ms and there is no long step for obtain's lock to span. Measuring that tick
# would pass while observing nothing, which is exactly the failure this guard exists to avoid.
q "call pgpm.maintain_all()" >/dev/null

# That warm-up tick also consumed obtain's work, so the MEASURED tick would have no partition to create
# and take no ACCESS EXCLUSIVE at all. Advance the frontier again, to the grid's new ceiling, so obtain
# has work in the same tick as the long regrain copy -- which is the whole point of the guard.
CEIL=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ml'::regclass")
q "insert into public.ml values ($((CEIL-1)), 'advances the frontier again')" >/dev/null

# Clear the log so every assertion below is about the MEASURED tick alone. Without this, the warm-up
# tick's own obtain entries satisfy the "did the work that takes the lock" check and it passes on stale
# evidence -- the same vacuous-pass shape the liveness witnesses exist to catch.
q "delete from pgpm.log where parent_table='public.ml'::regclass" >/dev/null

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
check "and regrained in the same tick" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action in ('regrain_copy','regrain_attach','regrain')")" "true"

exit "$fail"
