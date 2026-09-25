#!/usr/bin/env bash
# Guard maintain()'s auto-regrain step against running with no lock_timeout (issue #514). Run by CI
# (`./test.sh perf`).
#
# THE CONTRACT (docs/reference.md, regrain_step): "Under maintain the DETACH gives up after 200 ms (a
# skip_regrain row, retried next tick)". Every step of a tick fails fast on a lock it cannot get, because
# a PENDING ACCESS EXCLUSIVE blocks every request queued behind it: while the swap's DETACH waits for a
# writer, no session can so much as SELECT from the parent.
#
# THE DEFECT. `set local` dies at COMMIT, so maintain() re-applies set_config('lock_timeout', '200ms',
# true) after each of its boundaries -- except that it did not after the retain boundary, the one that
# precedes the auto-regrain block. regrain_step therefore ran under the SESSION default (0: wait forever).
# A writer holding one row in the source kept the DETACH's ACCESS EXCLUSIVE request queued for the length
# of its transaction, every read of the parent queued behind that request, and when the writer committed
# maintain swapped inside the same tick as if nothing had happened: no skip_regrain row, nothing in
# status(), the outage invisible after the fact.
#
# THE PROBE. Drive a regrain to the swap's doorstep (cursor at hi), take one row in the source from a
# second session and hold it, then run one maintain() tick from a third. Under the contract the tick
# returns while the writer is still holding, with exactly one `skip_regrain` row carrying the lock
# timeout and no swap, and a reader of the parent meanwhile is not locked out. With the defect the tick
# returns only after the writer commits, having swapped. The writer then commits and the next tick swaps
# for real, which is what proves the swap path was live and the deferral a deferral rather than a no-op.
#
# Every negative here ("did not swap", "reader not locked out") is paired with a witness that the
# conditions for the defect were present: the cursor was at hi so the measured tick WAS the swap tick,
# the session default lock_timeout really was 0, the writer's lock really was granted before the tick
# began and still held when it returned, and the swap really happened once the writer was gone.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   maintain_no_lock_timeout_after_retain -- the re-applied set_config after the retain boundary removed,
#                                            which is the pre-#514 procedure exactly
#
# Usage: maintain_regrain_lock_timeout.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
HOLD=${HOLD:-5}     # seconds the writer keeps its row open; the tick has to come back well inside it
fail=0

# client_min_messages=warning for every session: maintain()'s `drop trigger if exists` NOTICEs would
# otherwise land in the captured status below and in the console, and the guard reads that status exactly.
PGO="-c client_min_messages=warning"
q() { docker exec -e PGOPTIONS="$PGO" "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-64s %s\n' "$1" "$2"
  else printf 'FAIL  %-64s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
# A mutant that will not even install is NOT a pass: the guard would then be reported as failing for
# a reason that has nothing to do with what it asserts. Say which happened.
if ! docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-64s %s\n' "the module under test installed" "$INSTALL"; exit 1
fi

# --- fixture: 299 rows on ids 10..2990, so at step 1000 the monolith is [0, 3000); then one row at 20000
# to put the frontier far past it, which freezes the monolith and gives auto-regrain a target. The target
# step is 1000 too, so the regrain is three sub-ranges of 100 rows each. Asymmetric on purpose: one held
# row (55) against 299 settled ones, so a lost or duplicated row cannot cancel against another.
q "create table public.e (id bigint primary key, payload text)" >/dev/null
q "insert into public.e select g * 10, 'x' from generate_series(1, 299) g" >/dev/null
q "call pgpm.transmute('public.e', 'id', 1000)" >/dev/null
q "insert into public.e values (20000, 'frontier')" >/dev/null
q "select pgpm.set_regrain('public.e', '1000')" >/dev/null
q "select pgpm.resume('public.e')" >/dev/null
MONO=$(q "select child_name from pgpm.part where parent_table = 'public.e'::regclass and attached order by lo::bigint limit 1")

# Drive the copies by hand to the swap's doorstep. The FIRST regrain_step installs capture and copies
# nothing; the next three each copy one sub-range and advance the cursor. Once the cursor reaches hi
# (3000) the very next step is the swap, and that step is what the measured tick below performs.
q "do \$\$ declare s text; n int := 0; v_cur text; begin
  loop
    select regrain_cursor into v_cur from pgpm.config where parent_table = 'public.e'::regclass;
    exit when v_cur is not null and v_cur::numeric >= 3000;
    s := pgpm.regrain_step('public.e', '$MONO', '1000', 1000);
    n := n + 1;
    if n > 50 then raise exception 'setup did not converge: %', s; end if;
  end loop;
end \$\$" >/dev/null

check "LIVENESS: the cursor is at hi, so the measured tick is the swap tick" \
      "$(q "select regrain_cursor from pgpm.config where parent_table = 'public.e'::regclass")" "3000"
check "LIVENESS: the session default lock_timeout is 0 (wait forever)" \
      "$(q "select current_setting('lock_timeout')")" "0"

# Clear the log so every assertion below is about the MEASURED tick alone; the hand-driven steps above
# left regrain_copy rows that would otherwise pad the tick's record.
q "delete from pgpm.log" >/dev/null

# --- the writer: one row in the source, held open for HOLD seconds. ROW EXCLUSIVE on the parent and on
# the monolith, which is all it takes to keep an ACCESS EXCLUSIVE request waiting.
docker exec -e PGOPTIONS="$PGO" "$C" psql -U postgres -d "$DB" -qtA \
  -c "begin; insert into public.e values (55, 'held'); select pg_sleep($HOLD); commit;" >/dev/null 2>&1 &
WPID=$!
held=0
for _ in $(seq 1 200); do
  held=$(q "select count(*) from pg_locks where database = (select oid from pg_database where datname = current_database()) and relation = 'public.e'::regclass and mode = 'RowExclusiveLock' and granted")
  [ "${held:-0}" -gt 0 ] && break
  sleep 0.05
done
check "LIVENESS: the writer held its row before the tick began" \
      "$([ "${held:-0}" -gt 0 ] && echo true || echo false)" "true"

# --- the measured tick, from its own session, exactly as pg_cron would run it (session default settings).
STATUS_FILE=$(mktemp); T1_FILE=$(mktemp); trap 'rm -f "$STATUS_FILE" "$T1_FILE"' EXIT
T0=$(date +%s)
# The finish time is stamped by the tick's own subshell, so the duration printed below is the tick's and
# not the reader's sleep.
( docker exec -e PGOPTIONS="$PGO" "$C" psql -U postgres -d "$DB" -qtA -c "call pgpm.maintain('public.e')" >"$STATUS_FILE" 2>&1
  date +%s >"$T1_FILE" ) &
MPID=$!
# The consequence an operator would see, from a THIRD session while the writer is still holding: a plain
# read of the parent. Behind a pending ACCESS EXCLUSIVE it queues for as long as the writer holds; with
# the DETACH giving up at 200 ms there is nothing left to queue behind. The reader's 1 s is five times the
# contract's timeout and a fifth of the writer's hold, so neither verdict rides on a close call.
sleep 1.5
reader=$(docker exec -e PGOPTIONS="$PGO" "$C" psql -U postgres -d "$DB" -qtA -c "set lock_timeout = '1s'" \
           -c "select 'reader ok' from public.e limit 1" 2>&1 | tr '\n' ' ' | sed 's/ *$//')
wait $MPID
T1=$(cat "$T1_FILE")
still_held=$(q "select count(*) from pg_locks where database = (select oid from pg_database where datname = current_database()) and relation = 'public.e'::regclass and mode = 'RowExclusiveLock' and granted")
wait $WPID

check "the tick came back while the writer still held its row" \
      "$([ "${still_held:-0}" -gt 0 ] && echo true || echo false)" "true"
check "the tick reported the regrain deferred, not swapped" \
      "$(cat "$STATUS_FILE")" "archived=0 dropped=0 restored_fk=0 regrain=deferred regrain_deferred"
# Exact action and exact message: `skip_regrain` is the deferral row and 55P03's text is the reason, and
# these are the ONLY rows the tick may leave, so a swap (regrain_attach, regrain) or any other deferral
# shows up here by name rather than hiding behind a count.
check "the tick logged exactly the DETACH's lock timeout, and nothing else" \
      "$(q "select string_agg(action || ':' || coalesce(method, '<null>'), ' | ' order by id) from pgpm.log")" \
      "skip_regrain:canceling statement due to lock timeout"
check "a concurrent reader was not locked out behind the swap's request" "$reader" "reader ok"
echo "      (the tick took $((T1 - T0)) s against the writer's ${HOLD} s hold)"

# --- the writer has committed, so the deferral must now resolve: the next tick swaps (the captured row 55
# is reconciled under the DETACH's lock in that same tick). A few ticks are allowed in case one reconciles
# first; what is asserted is that the swap happened and where the rows ended up, not how many ticks.
swapped=""
for _ in 1 2 3 4 5; do
  q "call pgpm.maintain('public.e')" >/dev/null
  swapped=$(q "select string_agg(method, ',') from pgpm.log where action = 'regrain'")
  [ -n "$swapped" ] && break
done
check "LIVENESS: once the writer committed, a later tick swapped" "$swapped" "copy_swap_drop"
FINE_LO=$(q "select child_name from pgpm.part where parent_table = 'public.e'::regclass and attached and lo::bigint = 0 and hi::bigint = 1000")
FINE_HI=$(q "select child_name from pgpm.part where parent_table = 'public.e'::regclass and attached and lo::bigint = 2000 and hi::bigint = 3000")
check "LIVENESS: the fine children exist and are not the monolith" \
      "$([ -n "$FINE_LO" ] && [ -n "$FINE_HI" ] && [ "$FINE_LO" != "$MONO" ] && echo true || echo false)" "true"
# Identity, not a count: the held row and one settled row, each read back from the child that holds it.
check "the held row and a settled row each live in their own fine child" \
      "$(q "select string_agg(t.id || '->' || c.relname, ' ' order by t.id) from public.e t join pg_class c on c.oid = t.tableoid where t.id in (55, 2990)")" \
      "55->$FINE_LO 2990->$FINE_HI"
check "the monolith is gone" "$(q "select (to_regclass('public.$MONO') is null)::text")" "true"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
