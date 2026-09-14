#!/usr/bin/env bash
# Guard a maintenance tick against holding a data-coupled lock (issue #279). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# Two independent pairings, both driven from one maintain_all() sweep over two managed tables:
#
#   1. obtain (public.ml). pgpm.obtain takes ACCESS EXCLUSIVE on the PARENT (CREATE TABLE ... PARTITION
#      OF). Issue #347 split obtain out of maintain()/maintain_all() into its own procedure,
#      maintain_obtain(), and its own cron job -- an operator (or, as here, a probe modelling the worst
#      case) can still run it immediately before a maintain_all() tick in the same session, which is
#      exactly what this guard drives, so the property under test is unchanged: obtain's ACCESS EXCLUSIVE
#      must not survive into whatever long step follows it. The long step used to be the drain; #288
#      removed it and the DEFAULT with it, so it is now a REGRAIN copy microbatch.
#
#   2. retain (public.mg_ret), a second, throwaway table swept in the SAME maintain_all() call ahead of
#      ml (its name sorts first; pgpm.config is swept `order by parent_table`). retain's DROP also takes
#      ACCESS EXCLUSIVE on ITS parent (maintain()'s own comment: "retain DROPs partitions, which takes
#      ACCESS EXCLUSIVE on the parent"), immediately before maintain_all()'s loop moves on to ml's turn.
#      For this to leak into ml's regrain copy, EVERY commit standing between the two has to be missing:
#      maintain()'s OWN internal boundary right after retain, the (easy to miss) one before FK-validate
#      (issue #265 -- it commits unconditionally every tick, with or without an incoming FK, so it is
#      just as much a release point as the retain-specific one), and maintain_all()'s outer per-parent
#      commit. Confirmed the hard way: a mutant missing all but the #265 boundary still passed this
#      guard, because that ONE boundary alone was enough to release mg_ret's lock before ml's turn.
#      A single table cannot drive this pairing at all: retain()/write-block always pick the OLDEST
#      eligible partition first (`order by lo`), which is always the monolith regrain needs intact, so
#      retain and regrain can never coexist as short-lock-then-long-step on one table. write-block itself
#      was ruled out entirely: CREATE TRIGGER takes ShareRowExclusiveLock, which does not conflict with a
#      plain SELECT, so no reader-probe technique can observe its lock surviving anything -- confirmed
#      empirically, not merely assumed from the old (mistaken) comment this file used to carry.
#
# The assertion is the consequence an operator would actually see, not the lock mode: a plain SELECT
# against each parent, with a lock_timeout far shorter than the regrain batch, must never time out during
# a tick. obtain's and retain's own windows are each ~1 ms (pure metadata), far under the reader's 1 s
# timeout, so neither verdict rides on a close call.
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

# --- mg_ret: the throwaway retain-drop table. Tiny, and its name sorts before "ml" so it gets its turn
# first in maintain_all()'s `order by parent_table` sweep. No retention-eligible partition yet -- the
# frontier is only advanced after the warm-up tick, below, so the warm-up (which also sweeps this table)
# does not consume it.
q "create table public.mg_ret (id bigint primary key, v text)" >/dev/null
q "insert into public.mg_ret select g, 'x' from generate_series(1,100) g" >/dev/null
q "call pgpm.transmute('public.mg_ret', 'id', 100000::bigint, p_retain => 100000::bigint, p_paused => false)" >/dev/null

# --- ml: the regrain long-step table, unchanged in shape from before #347.
q "create table public.ml (id bigint primary key, v text)" >/dev/null
q "insert into public.ml select g, repeat('x',60) from generate_series(1,$MONO) g" >/dev/null
q "call pgpm.transmute('public.ml','id', $MONO::bigint, p_paused => false)" >/dev/null
# Advance the frontier to the TOP of the grid. Two things depend on this: it freezes the monolith (its
# whole range now sits at/below the grid floor, so auto-regrain has a target at all) AND gives the
# maintain_obtain() call below a partition to create -- without it neither takes any lock and the guard
# would pass having observed nothing. The grid's ceiling is read back rather than assumed, since transmute
# now builds it during the cutover.
HI=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ml'::regclass")
q "insert into public.ml values ($((HI-1)), 'advances the frontier to the grid ceiling')" >/dev/null
q "vacuum analyze public.ml" >/dev/null
# Auto-regrain of the coarse monolith into fine children is the long step in a tick now. A small target
# step means many copy microbatches, so the tick is long enough to span if a boundary goes missing.
q "update pgpm.config set regrain_batch=$BATCH where parent_table='public.ml'::regclass" >/dev/null
# Sub-range width chosen from measurement, not guessed: at 2,000,000 a copy tick runs 2.1-2.4 s, which
# comfortably outlasts the ~150 ms it takes the probe's own psql session to start. At 100k and at 500k the
# tick finished before the probe could read, and the guard reported nothing observed.
q "select pgpm.set_regrain('public.ml', '2000000')" >/dev/null

# One warm-up tick, over BOTH tables. A regrain's FIRST tick returns 'prepared': it installs change
# capture and copies nothing, so it takes ~26 ms and there is no long step for a lock to span. Measuring
# that tick would pass while observing nothing, which is exactly the failure this guard exists to avoid.
# mg_ret has nothing eligible yet (see above), so this tick is a no-op for it.
q "call pgpm.maintain_all()" >/dev/null

# Now give mg_ret something to drop in the MEASURED tick: advance ITS frontier past its own oldest
# partition. p_retain (100000, one step) makes everything up to the new frontier minus one step eligible;
# retain()/write-block pick the oldest first, so this is deterministic regardless of how many partitions
# end up eligible.
HIA=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.mg_ret'::regclass")
q "insert into public.mg_ret values ($((HIA-1)), 'advances mg_ret past its own oldest partition')" >/dev/null

# Clear the log so every assertion below is about the MEASURED tick alone. Without this, transmute's own
# initial obtain calls (or the warm-up tick's regrain 'prepared' entry) satisfy the "did the work that
# takes the lock" checks and they pass on stale evidence -- the same vacuous-pass shape the liveness
# witnesses exist to catch.
q "delete from pgpm.log" >/dev/null

q "create table public.probe (attempts int, timeouts int, saw_tick boolean, attempts_ret int, timeouts_ret int)" >/dev/null
q "create table public.done (x int)" >/dev/null

docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "call pgpm.maintain_obtain('public.ml')" -c "call pgpm.maintain_all()" \
  -c "insert into public.done values (1)" >/tmp/ml_bg.log 2>&1 &
BG=$!

# maintain_obtain() and maintain_all() are two separate top-level statements (issue #347: they are two
# separate cron jobs in production), so obtain's own commit already ends its transaction before
# maintain_all() even starts -- there is no longer a shared transaction for its lock to leak across.
# Running it immediately first, in the same session, keeps the "did real work" liveness witness below
# meaningful without changing what the probe watches for. maintain_all() itself now sweeps BOTH tables:
# mg_ret's retain-drop first, then ml's write-block/archive/retain(no-op)/regrain.
#
# Two things this probe has to get right, both learned by getting them wrong:
#
# 1. COMMIT after every read. AccessShareLock is held to transaction end and a DO block is ONE
#    transaction, so a probe that just loops on SELECT pins AccessShareLock for its whole run. retain
#    then cannot get ACCESS EXCLUSIVE within its 200 ms lock_timeout and DEFERS -- the tick logs
#    skip_retain, takes no strong lock at all, and the guard passes having tested nothing.
#
# 2. Do not read until the tick has had its chance. Each step fails fast by design, so a probe holding
#    any lock at the start of the tick suppresses the very step whose lock is under test. Wait for the
#    tick, give it a window, and only then start reading -- by which point a pre-fix run is still holding
#    a lock from an earlier step into the regrain copy, and a post-fix run has committed and released it.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; t int := 0; na int := 0; ta int := 0; saw boolean := false;
begin
  for i in 1 .. 2000000 loop
    exit when exists(select 1 from pg_stat_activity
                      where datname = current_database() and pid <> pg_backend_pid()
                        and query like '%maintain_all%' and state = 'active');
    commit;
  end loop;
  saw := true;
  perform pg_sleep(0.5);            -- obtain/retain are each ~1 ms; the regrain copy that follows is ~2.3 s
  commit;
  while not exists(select 1 from public.done) loop
    begin
      -- 150 ms, not 1 s. The unit of observation costs one lock_timeout, so a 1 s timeout could fit only
      -- ONE OR TWO attempts into the ~1.8 s of blocked window that remains after the 0.5 s head start --
      -- and it showed: against its own mutant this guard scored exactly 1 timeout, a margin of a single
      -- observation. Any millisecond-scale shift in a step's duration then flips it to 0 and the guard
      -- silently stops discriminating, which is precisely the failure mode bench/discriminate.sh exists
      -- to catch (and did, on issue #299). At 150 ms the same window is ~12 observations wide, while
      -- staying ~150x above obtain's own ~1 ms post-fix lock window, so neither verdict rides on timing.
      set local lock_timeout = '150ms';
      perform 1 from public.ml limit 1;
    exception when others then t := t + 1; end;
    n := n + 1;
    commit;                         -- release AccessShareLock so the tick is never starved
    begin
      set local lock_timeout = '150ms';
      perform 1 from public.mg_ret limit 1;
    exception when others then ta := ta + 1; end;
    na := na + 1;
    commit;
  end loop;
  insert into public.probe values (n, t, saw, na, ta);
end \$p\$;" >/dev/null 2>&1
wait $BG

check "the probe overlapped a running tick"     "$(q "select saw_tick::text from public.probe")" "true"
check "a concurrent reader is never locked out (ml)"     "$(q "select timeouts::text from public.probe")"     "0"
check "a concurrent reader is never locked out (mg_ret)" "$(q "select timeouts_ret::text from public.probe")" "0"
check "at least one read landed inside the tick (ml)" \
      "$(q "select (attempts > 0)::text from public.probe")" "true"
check "at least one read landed inside the tick (mg_ret)" \
      "$(q "select (attempts_ret > 0)::text from public.probe")" "true"
# These are what stop the guard passing vacuously. A tick starved of its locks logs skip_obtain/skip_retain,
# takes no ACCESS EXCLUSIVE, and would sail through the reader assertions having proved nothing -- so every
# step under test must be shown to have done real work, and a *_skip must not count as work.
check "the tick did the work that takes the lock (obtain)" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action = 'obtain'")" "true"
check "the tick did the work that takes the lock (retain)" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.mg_ret'::regclass and action = 'retain_drop'")" "true"
check "and regrained in the same tick" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action in ('regrain_copy','regrain_attach','regrain')")" "true"

exit "$fail"
