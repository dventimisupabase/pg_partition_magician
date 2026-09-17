#!/usr/bin/env bash
# Demonstrates the fix committed as a585ae8 ("pair aborted lock waits instead of letting a return
# steal them", issue #392): bench/lock_view.py's on_lock/on_lock_ret must consume the PENDING entry
# for a pid BEFORE filtering on the oid's catalog status, not after. NOT run by CI or ./test.sh, and
# nothing here calls it automatically -- it is a committed, runnable record of the discrimination
# proof that justified those twenty lines of BPF C (bench/lock_view.py:108-121), which otherwise read
# as redundant complexity to anyone who has not seen the defect it prevents.
#
# THE DEFECT THIS GUARDS AGAINST
#
# lock_timeout, statement_timeout and deadlock_timeout all abort a wait with an ERROR that
# PostgreSQL escapes via siglongjmp: the frame is unwound, never returned through, so a uretprobe's
# return trampoline never fires for that call. If the catalog filter lived on the REQUEST side (as
# it did before a585ae8), a catalog request would never enter the `pending` map at all, so a
# non-catalog request's aborted wait would leave ITS pending entry orphaned. Since catalog locks are
# 76-80% of a watched backend's traffic (measured on this project's own fixtures), the very next
# LockRelationOid return on that pid is almost always a catalog one, and it would consume the
# orphaned entry: a FABRICATED grant, carrying the stale non-catalog oid and mode with a fresh,
# meaningless wait_ns, while the real lost wait incremented no counter at all. A lost wait rendered
# as a clean instant grant is the silent-overflow defect this whole instrument exists to eliminate,
# wearing a different hat.
#
# The fix moves the filter to the RETURN side: on_lock tracks every call from a watched backend,
# catalog included, so entry and exit always pair on the SAME request; on_lock_ret consumes
# whichever entry is there unconditionally, and only then decides whether to emit.
#
# WHAT THIS SCRIPT DOES
#
#   1. Creates a scratch table in the given database (dropped at the end; never touches a fixture
#      used by any other track).
#   2. Starts bench/lock_view.py watching that table's oid.
#   3. Session A takes ACCESS EXCLUSIVE on the table and holds it across a sleep, so session B is
#      guaranteed to contend.
#   4. Session B, with a short lock_timeout, requests the same lock, times out and aborts, then
#      runs one harmless catalog SELECT (the "next LockRelationOid return" the defect exploits).
#   5. Stops the probe and prints every "lock" event plus the final tail record.
#
# WHAT TO LOOK FOR
#
#   - The tail record reads unmatched: 1 (session B's aborted wait was counted, not lost).
#   - No "lock" event anywhere in the stream carries session B's pid: it must never appear as a
#     fabricated instant grant.
#
# Reverting the fix (move the `if req_oid < FIRST_NORMAL: return 0;` filter from on_lock_ret back
# onto on_lock, before pending.update) reproduces the opposite on a rerun: unmatched: 0, and a
# spurious "lock" event on session B's pid whose wait_ns matches the lock_timeout window almost
# exactly (a 100ms lock_timeout produced wait_ns: 100488505 in the original proof run -- see
# .superpowers/sdd/2026-09-16-lock-sequence-renderer/task-4-report.md for that exact side-by-side).
#
# USAGE
#
#   bench/lock_timeout_pairing_demo.sh <container> <db>
#   bench/lock_timeout_pairing_demo.sh pgpm_test-locktrace lv_smoke
#
# PREREQUISITES
#
#   The locktrace compose profile, up and healthy: docker compose --profile locktrace up -d
#   <db> must already exist in that container (createdb <db> first if it does not).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
TABLE=public.lock_timeout_pairing_demo
EVENTS=/tmp/pgpm_pairing_demo.jsonl
PLOG=/tmp/pgpm_pairing_demo.log

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }

if ! docker exec "$C" python3 -c 'import bcc' 2>/dev/null; then
  echo "error: $C has no bcc. Start the locktrace service:" >&2
  echo "  docker compose --profile locktrace up -d" >&2
  exit 1
fi

q "drop table if exists $TABLE" >/dev/null
q "create table $TABLE (id int)" >/dev/null
OID=$(q "select '$TABLE'::regclass::oid")
[ -n "$OID" ] || { echo "error: $TABLE did not resolve to an oid" >&2; exit 1; }
echo "watching $TABLE, oid $OID"

docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
docker exec -d "$C" sh -c "python3 /repo/bench/lock_view.py $OID $EVENTS > $PLOG 2>&1"

ready=false
for _ in $(seq 1 30); do
  if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "error: probe never became READY" >&2
  docker exec "$C" cat "$PLOG" >&2
  exit 1
fi

# Session A: acquire and hold ACCESS EXCLUSIVE for long enough to guarantee overlap with B, then
# release. Detached so this script can start B while A is still holding the lock.
docker exec -d "$C" psql -U postgres -d "$DB" \
  -c "BEGIN;" -c "LOCK TABLE $TABLE IN ACCESS EXCLUSIVE MODE;" \
  -c "SELECT pg_sleep(8);" -c "COMMIT;"

# Give A time to actually take the lock before B tries to contend for it.
sleep 2
held=$(q "select mode from pg_locks where relation = '$TABLE'::regclass and granted")
echo "session A holds: ${held:-<nothing -- session A did not acquire the lock in time>}"

# Session B: lock_timeout aborts the conflicting wait, then one harmless catalog SELECT -- the
# "next LockRelationOid return" the pre-fix defect exploited to fabricate a grant.
echo "session B: requesting the same lock under a 100ms lock_timeout (expect an ERROR below)"
docker exec "$C" psql -U postgres -d "$DB" \
  -c "SET lock_timeout='100ms';" -c "BEGIN;" \
  -c "LOCK TABLE $TABLE IN ACCESS EXCLUSIVE MODE;" \
  -c "ROLLBACK;" -c "SELECT relname FROM pg_class LIMIT 1;"

# Let session A's sleep finish and commit before stopping the probe, so both sessions' full
# activity is captured.
wait

docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f lock_view.py >/dev/null 2>&1 || break
  sleep 1
done

echo
echo "--- lock events ---"
docker exec "$C" sh -c "grep '\"kind\": \"lock\"' $EVENTS || true"
echo "--- tail record ---"
docker exec "$C" tail -1 "$EVENTS"

q "drop table if exists $TABLE" >/dev/null
echo
echo "expected: exactly one 'lock' event's pid never repeats with a fabricated instant grant, and"
echo "the tail record reads unmatched: 1 (not 0)."
