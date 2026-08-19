#!/usr/bin/env bash
# Guard transmute against waiting forever for a lock (issue #309). Run by CI (`./test.sh perf`).
#
# THE DEFECT. transmute takes ACCESS EXCLUSIVE twice on the operator's live table: phase 1's
# ADD CONSTRAINT, and phase 3's RENAME. With no lock_timeout it waits indefinitely for whatever is
# already holding a conflicting lock -- and a PENDING AccessExclusive request blocks every lock request
# queued behind it, including plain SELECTs that conflict with nothing running. So one slow query turns
# transmute's wait into a full outage of the table, with nothing to break it.
#
# WHY A SHELL HARNESS. Asserting this needs a SECOND SESSION holding a lock while a first attempts the
# conversion, and pgTAP gives one session per file. Same reason bench/transmute_lock.sh is here.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   1. transmute FAILS, with SQLSTATE 55P03 (lock_not_available) specifically. Not "fails somehow": a
#      typo in the CALL, a missing table, or a bad parameter would all fail too, and would pass a test
#      that only asked for failure.
#   2. It fails CLEANLY: the table is still an ordinary relation with no pgpm state behind it. Phase 1
#      is where the first AEL is taken, so a correct timeout leaves nothing committed.
#   3. LIVENESS WITNESS: with the blocker released, the SAME call succeeds. Without this the guard
#      passes vacuously against a build where transmute is broken for some unrelated reason -- the
#      exact absence-of-defect vs absence-of-setup confusion CLAUDE.md warns about.
#
# It asserts SQLSTATE and end state, not wall-clock, so there is nothing to flake on a shared runner.
# The one time bound is a loose hang ceiling (HANG_CEILING, many times the lock_timeout) that exists
# only so an unfixed build reports FAIL instead of hanging CI forever.
#
# Usage: transmute_lock_timeout.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
ROWS=${ROWS:-20000}
LOCK_TIMEOUT=${LOCK_TIMEOUT:-2s}
HANG_CEILING=${HANG_CEILING:-60}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-56s %s\n' "$1" "$2"
  else printf 'FAIL  %-56s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

# The key must contain the control column or transmute refuses in preflight, before taking any lock --
# which would make every assertion below fire for the wrong reason. The liveness witness caught exactly
# that while this guard was being written.
q "create table public.lt (id bigint, created_at timestamptz not null, v text, primary key (created_at, id))" >/dev/null
q "insert into public.lt select g, now() - (g || ' seconds')::interval, repeat('x', 50) from generate_series(1, $ROWS) g" >/dev/null
q "vacuum analyze public.lt" >/dev/null

# The blocker: a session holding ACCESS SHARE on the table, which conflicts with the ACCESS EXCLUSIVE
# transmute needs. Held open by a sleeping transaction rather than a client-side pause, so the lock is
# genuinely held server-side for the whole window and does not depend on this script's timing. Tagged
# with an application_name so the teardown below can terminate exactly this backend rather than pattern
# matching on query text, which would also match this guard's own polling.
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "set application_name = 'pgpm_lt_blocker'" \
  -c "begin; select count(*) from public.lt; select pg_sleep($HANG_CEILING); commit;" >/dev/null 2>&1 &
BLOCKER=$!

# Wait for the blocker's lock to actually appear before attempting the conversion. Polling for the lock
# (rather than sleeping a guessed interval) is what stops this from racing on a slow runner: if the
# blocker never got its lock, the conversion would succeed and the guard would pass having tested
# nothing. Treated as a hard failure below rather than silently proceeding.
HELD=false
for _ in $(seq 1 100); do
  n=$(q "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
          where c.relname = 'lt' and l.mode = 'AccessShareLock' and l.granted")
  if [ "${n:-0}" -ge 1 ]; then HELD=true; break; fi
  sleep 0.2
done
check "the blocker is holding a conflicting lock" "$HELD" "true"

# Attempt the conversion under the hang ceiling, so a build that waits forever reports FAIL instead of
# wedging CI. Done with a background process and a polling deadline rather than coreutils `timeout`,
# which is absent on macOS and would make this guard runnable only on the CI runner.
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "call pgpm.transmute('public.lt', 'created_at', interval '1 day', p_lock_timeout => '$LOCK_TIMEOUT')" \
  >/tmp/lt_attempt.log 2>&1 &
ATTEMPT=$!
DEADLINE=$(( SECONDS + HANG_CEILING ))
while kill -0 "$ATTEMPT" 2>/dev/null && [ "$SECONDS" -lt "$DEADLINE" ]; do sleep 0.5; done
if kill -0 "$ATTEMPT" 2>/dev/null; then
  kill "$ATTEMPT" 2>/dev/null; RC=124
else
  wait "$ATTEMPT"; RC=$?
fi
OUT=$(cat /tmp/lt_attempt.log)

if [ "$RC" = "124" ]; then
  check "transmute gives up instead of waiting forever" "hung past ${HANG_CEILING}s" "55P03"
else
  case "$OUT" in
    *55P03*|*"canceling statement due to lock timeout"*)
      check "transmute gives up instead of waiting forever" "55P03" "55P03" ;;
    *) check "transmute gives up instead of waiting forever" "other: $(echo "$OUT" | tr '\n' ' ' | cut -c1-90)" "55P03" ;;
  esac
fi

# It must fail CLEANLY: phase 1 is where the first AEL is taken, so nothing should be committed.
check "the table is untouched"        "$(q "select relkind from pg_class where oid = 'public.lt'::regclass")" "r"
check "no pgpm config row was left"   "$(q "select count(*) from pgpm.config where parent_table = 'public.lt'::regclass")" "0"
check "no in-flight record was left"  "$(q "select count(*) from pgpm.transmute_inflight")" "0"

# LIVENESS WITNESS. Release the blocker and run the identical call: it must succeed. This is what
# separates "transmute correctly refused to wait" from "transmute is broken in this build".
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "select pg_terminate_backend(pid) from pg_stat_activity
       where datname = '$DB' and application_name = 'pgpm_lt_blocker'" >/dev/null 2>&1
kill "$BLOCKER" 2>/dev/null
wait "$BLOCKER" 2>/dev/null

docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "call pgpm.transmute('public.lt', 'created_at', interval '1 day', p_lock_timeout => '$LOCK_TIMEOUT')" \
  >/tmp/lt_ok.log 2>&1
check "the same call succeeds once unblocked" "$(q "select relkind from pg_class where oid = 'public.lt'::regclass")" "p"

exit "$fail"
