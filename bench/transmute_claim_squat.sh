#!/usr/bin/env bash
# Guard transmute's claim against an unprivileged squatter (issue #405). Run by CI (`./test.sh perf`).
#
# THE BAR: a role that can do nothing but CONNECT must not be able to stop pgpm from undoing an abandoned
# conversion. Before #405 it could. transmute claimed its table with a SESSION advisory lock keyed on
# hashtextextended('pgpm_transmute:' || oid), and both recovery paths -- pgpm._transmute_reap and
# pgpm.transmute_abort -- decided "is this conversion still running?" by trying to TAKE that same lock.
# Advisory locks carry no ACL and that key is public (the formula is in install.sql, the oid is in
# pg_class), so anyone could hold it. Grabbing it the instant a crashed conversion released it made the
# reaper read "still running" forever: the pgpm_monolith_bound CHECK left behind by the crash went on
# REJECTING every write outside [lo, hi) with no automated or manual way back, because transmute_abort
# consulted the very same lock and refused too.
#
# WHAT THIS DRIVES. A claim row whose owning session is genuinely gone (the state a died-mid-run
# conversion leaves), plus a SECOND session squatting the old advisory key, then:
#
#   1. pgpm._transmute_reap() must still undo the abandoned conversion.
#   2. pgpm.transmute_abort() must still work on a second, independently abandoned conversion.
#
# THE LIVENESS WITNESS, which is the whole reason this guard is not self-satisfying. "The reaper was not
# starved" is a negative, and a negative is equally satisfied by a run where the squat never happened at
# all -- a backgrounded session that died early, a key computed from the wrong oid, a psql that never
# connected. So this asserts, from a THIRD session and before touching the reaper, that the squatter is
# real: it holds an advisory lock, on the exact key the pre-#405 code used, and it is still connected.
# If that witness fails the guard fails, rather than reporting a clean bill of health for a squat that
# was never in place. (bench/discriminate.sh's transmute_claim_squat mutation restores the advisory-lock
# reaper and requires this guard to FAIL against it.)
#
# Usage: transmute_claim_squat.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -qv ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null 2>&1 \
  || { echo "FAIL  could not install $INSTALL"; exit 1; }
# A witness that the install actually landed, anchored on what this guard WRITES: it inserts claim rows
# naming their owner session, so those two columns existing is the real precondition. Without it a failed
# install (a missing database, as this guard itself shipped with once, or a mutant that will not load)
# leaves every assertion below querying a database with no pgpm in it, and the guard reports a wall of
# confusing failures instead of naming the cause.
check "pgpm installed into $DB, with the claim's owner columns" \
  "$(q "select count(*)::int from information_schema.columns
         where table_schema = 'pgpm' and table_name = 'transmute_inflight'
           and column_name in ('owner_pid','owner_backend_start')")" "2"

# Two tables, each left in the state a crashed conversion leaves: a claim row plus the live
# pgpm_monolith_bound CHECK that rejects out-of-range writes. sq_reap is for the reaper, sq_abort for
# the manual escape hatch.
q "drop table if exists public.sq_reap, public.sq_abort cascade;
   create table public.sq_reap  (id bigint primary key);
   create table public.sq_abort (id bigint primary key);
   alter table public.sq_reap  add constraint pgpm_monolith_bound check (id >= 0 and id < 100) not valid;
   alter table public.sq_abort add constraint pgpm_monolith_bound check (id >= 0 and id < 100) not valid;
   delete from pgpm.transmute_inflight
    where parent_table in ('public.sq_reap'::regclass,'public.sq_abort'::regclass);" >/dev/null

# A REAL but dead owner pid, not a synthetic null: a crashed conversion leaves a pid that was live and
# now is not, and that is the case the liveness check has to get right. Take a session's pid, then let
# the session end.
DEAD_PID=$(q "select pg_backend_pid()")
# sq_reap only, for now: the reaper below sweeps EVERY abandoned claim, so registering sq_abort's here
# would have it reaped before transmute_abort ever saw it, and the abort assertion would then be testing
# "already gone" rather than "abort works under a squat". It is registered after the reap instead.
q "insert into pgpm.transmute_inflight (parent_table,nsp,rel,control_kind,lo,hi,owner_pid,owner_backend_start)
   values ('public.sq_reap'::regclass,'public','sq_reap','id','0','100',$DEAD_PID, now());" >/dev/null
check "the dead owner's session really is gone" \
  "$(q "select pgpm._session_alive($DEAD_PID, now())")" "f"

# THE SQUAT. A second session takes the pre-#405 key for sq_reap and holds it. Backgrounded, so it stays
# connected while the reaper runs. Both statements share one -c here, unlike the live-owner session far
# below which has to split them: a SESSION advisory lock is held independently of any transaction and
# shows up in pg_locks immediately, whereas that session's INSERT is ordinary row data and stays
# invisible to the reaper until its transaction commits.
KEY=$(q "select hashtextextended('pgpm_transmute:' || 'public.sq_reap'::regclass::oid::text, 0)")
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "select pg_advisory_lock($KEY); select pg_sleep(60);" >/dev/null 2>&1 &
SQUAT_SHELL=$!
trap 'kill $SQUAT_SHELL 2>/dev/null' EXIT

# Wait for the squatter to actually hold the lock, rather than sleeping a guessed interval and hoping.
for _ in $(seq 1 40); do
  held=$(q "select count(*)::int from pg_locks
             where locktype = 'advisory'
               and ((classid::bigint << 32) | objid::bigint) = $KEY and granted")
  [ "${held:-0}" -ge 1 ] && break
  sleep 0.25
done

# ---- the liveness witness: the squat is real, on the right key, and still connected ----
check "a squatter holds the pre-#405 advisory key" \
  "$(q "select count(*)::int from pg_locks
         where locktype = 'advisory'
           and ((classid::bigint << 32) | objid::bigint) = $KEY and granted")" "1"
check "the squatting session is still connected" \
  "$(q "select count(*)::int from pg_stat_activity a join pg_locks l on l.pid = a.pid
         where l.locktype = 'advisory'
           and ((l.classid::bigint << 32) | l.objid::bigint) = $KEY")" "1"
# ...and it is a squat, not this conversion's own claim: the claim's recorded owner is a different,
# dead session. Without this, a guard could "prove" the squat while accidentally squatting as the owner.
check "the squatter is not the claim's recorded owner" \
  "$(q "select count(*)::int from pg_locks l
         where l.locktype = 'advisory'
           and ((l.classid::bigint << 32) | l.objid::bigint) = $KEY
           and l.pid = $DEAD_PID")" "0"

# ---- the property under test ----
# The verdict rides on what happened to THIS table, never on the reaper's return count. `_transmute_reap()
# >= 1` reads like the property but is not it: the sweep is database-wide, so any other abandoned claim
# satisfies it while sq_reap sits untouched behind the squat -- measured, against this guard's own mutant.
q "select pgpm._transmute_reap()" >/dev/null
check "the claim row is gone" \
  "$(q "select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.sq_reap'::regclass")" "0"
check "the write-rejecting bound is gone" \
  "$(q "select count(*)::int from pg_constraint
         where conrelid = 'public.sq_reap'::regclass and conname = 'pgpm_monolith_bound'")" "0"
check "it logged the reap" \
  "$(q "select count(*)::int from pgpm.log
         where parent_table = 'public.sq_reap'::regclass and action = 'transmute_reap'")" "1"

# transmute_abort, the manual escape hatch, on a table whose key is squatted too.
q "insert into pgpm.transmute_inflight (parent_table,nsp,rel,control_kind,lo,hi,owner_pid,owner_backend_start)
   values ('public.sq_abort'::regclass,'public','sq_abort','id','0','100',$DEAD_PID, now());" >/dev/null
check "sq_abort's abandoned claim is registered" \
  "$(q "select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.sq_abort'::regclass")" "1"
KEY2=$(q "select hashtextextended('pgpm_transmute:' || 'public.sq_abort'::regclass::oid::text, 0)")
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "select pg_advisory_lock($KEY2); select pg_sleep(60);" >/dev/null 2>&1 &
SQUAT2=$!
trap 'kill $SQUAT_SHELL $SQUAT2 2>/dev/null' EXIT
for _ in $(seq 1 40); do
  held2=$(q "select count(*)::int from pg_locks
              where locktype = 'advisory'
                and ((classid::bigint << 32) | objid::bigint) = $KEY2 and granted")
  [ "${held2:-0}" -ge 1 ] && break
  sleep 0.25
done
check "a squatter holds sq_abort's key too" "${held2:-0}" "1"
check "transmute_abort still undoes it" \
  "$(q "select pgpm.transmute_abort('public.sq_abort')")" "t"
check "sq_abort's bound is gone" \
  "$(q "select count(*)::int from pg_constraint
         where conrelid = 'public.sq_abort'::regclass and conname = 'pgpm_monolith_bound'")" "0"

# ---- the discriminator, in the other direction: a LIVE owner must still be left alone ----
# The fix must not have simply made the reaper unconditional. A claim whose owner session is genuinely
# alive is not abandoned, and reaping it would drop the bound out from under a running conversion.
q "drop table if exists public.sq_live cascade; create table public.sq_live (id bigint primary key);
   alter table public.sq_live add constraint pgpm_monolith_bound check (id >= 0 and id < 100) not valid;
   delete from pgpm.transmute_inflight where parent_table = 'public.sq_live'::regclass;" >/dev/null
# A session that stays connected, registering ITSELF as the claim's owner, then holds still. The insert
# and the sleep are SEPARATE -c flags deliberately: psql wraps multiple statements in one -c into a
# single implicit transaction, so combining them would leave the claim uncommitted -- and therefore
# invisible to the reaper -- for the whole sleep, and this block would be testing nothing.
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "insert into pgpm.transmute_inflight (parent_table,nsp,rel,control_kind,lo,hi,owner_pid,owner_backend_start)
      values ('public.sq_live'::regclass,'public','sq_live','id','0','100',
              pg_backend_pid(),(select backend_start from pg_stat_activity where pid = pg_backend_pid()));" \
  -c "select pg_sleep(60);" >/dev/null 2>&1 &
LIVE_OWNER=$!
trap 'kill $SQUAT_SHELL $SQUAT2 $LIVE_OWNER 2>/dev/null' EXIT
for _ in $(seq 1 40); do
  [ "$(q "select count(*)::int from pgpm.transmute_inflight where parent_table='public.sq_live'::regclass")" = "1" ] && break
  sleep 0.25
done
check "the live owner's claim is registered" \
  "$(q "select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.sq_live'::regclass")" "1"
check "its recorded session reads as alive" \
  "$(q "select pgpm._session_alive(owner_pid, owner_backend_start) from pgpm.transmute_inflight
         where parent_table = 'public.sq_live'::regclass")" "t"
q "select pgpm._transmute_reap()" >/dev/null
check "the reaper leaves a LIVE conversion alone" \
  "$(q "select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.sq_live'::regclass")" "1"
check "and leaves its bound in place" \
  "$(q "select count(*)::int from pg_constraint
         where conrelid = 'public.sq_live'::regclass and conname = 'pgpm_monolith_bound'")" "1"

kill $SQUAT_SHELL $SQUAT2 $LIVE_OWNER 2>/dev/null
[ "$fail" = 0 ] && echo "transmute_claim_squat: PASS" || echo "transmute_claim_squat: FAIL"
exit $fail
