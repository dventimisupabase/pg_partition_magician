#!/usr/bin/env bash
# Demonstrates the fix committed as a585ae8 ("pair aborted lock waits instead of letting a return
# steal them", issue #392): bench/lock_view.py's on_lock/on_lock_ret must consume the PENDING entry
# for a pid BEFORE filtering on the oid's catalog status, not after. RUN BY CI as the asserting half
# of the `lockview` track (./test.sh lockview, .github/workflows/lockview.yml, issue #398): it is the
# only check anywhere that fails when that filter placement is undone, since every cheap check passed
# the defect. It is still readable as what it was first written to be -- the committed record of the
# discrimination proof that justified those twenty lines of BPF C (bench/lock_view.py:108-121), which
# otherwise read as redundant complexity to anyone who has not seen the defect it prevents.
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
#   5. Waits for session A's transaction to commit, then stops the probe and prints every "lock"
#      event plus the final tail record.
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
# exactly: a 100ms lock_timeout produced wait_ns: 100488505 in the original proof run. That number
# is recorded HERE because this header is now its only home -- the task report it was first written
# into lived in an untracked scratch directory that no checkout ever had, and citing it was citing
# nothing.
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
# HOST-side, unlike the two above: session A runs as an attached `docker exec` backgrounded by this
# shell, so its output arrives here rather than in the container (see where it is launched).
ALOG=/tmp/pgpm_pairing_demo.session_a.log
BLOG=/tmp/pgpm_pairing_demo.session_b.log
CAP=/tmp/pgpm_pairing_demo.capture.jsonl
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-64s %s\n' "$1" "$2"
  else printf 'FAIL  %-64s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

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
# release. Backgrounded as a HOST shell job (`... &`), deliberately NOT `docker exec -d` (issue
# #395): the detached form returns on the host the instant the container accepts the command, so it
# creates no job, and the `wait` further down had nothing to wait on. Attached-and-backgrounded is
# the form that gives this script something real to wait for. Its output goes to $ALOG so it cannot
# interleave with the transcript printed below.
docker exec "$C" psql -U postgres -d "$DB" \
  -c "BEGIN;" -c "LOCK TABLE $TABLE IN ACCESS EXCLUSIVE MODE;" \
  -c "SELECT pg_sleep(8);" -c "COMMIT;" > "$ALOG" 2>&1 &
A_JOB=$!

# Poll until A's lock is actually GRANTED, rather than sleeping a guessed interval, and FAIL if it
# never is. This is the demo's liveness witness, and it is not decoration: everything this script
# looks for afterwards is a NEGATIVE (no fabricated grant carrying B's pid), and a run in which A
# never took the lock satisfies every one of those negatives while proving nothing whatsoever --
# B would not contend, would not time out, and would leave no aborted wait for anything to steal.
# Absence-of-defect and absence-of-setup must not look alike here.
#
# ~100 ms per `docker exec` sample is affordable against THIS window and would not be against a
# narrow one: A holds the lock for 8 s, twenty times the cost of observing it. The check is worth
# making explicitly, because a probe that cannot fit inside the window it measures has already cost
# this repo a round trip.
held=""
for _ in $(seq 1 30); do
  held=$(q "select mode from pg_locks where relation = '$TABLE'::regclass
            and granted and mode = 'AccessExclusiveLock'")
  [ -n "$held" ] && break
  sleep 0.1
done
if [ -z "$held" ]; then
  echo "error: session A never acquired ACCESS EXCLUSIVE on $TABLE, so session B would not have" >&2
  echo "       contended and this run would demonstrate nothing. Session A's output:" >&2
  cat "$ALOG" >&2
  kill "$A_JOB" 2>/dev/null
  wait "$A_JOB" 2>/dev/null
  docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
  q "drop table if exists $TABLE" >/dev/null
  exit 1
fi
echo "session A holds: $held"

# Session B: lock_timeout aborts the conflicting wait, then one harmless catalog SELECT -- the
# "next LockRelationOid return" the pre-fix defect exploited to fabricate a grant.
echo "session B: requesting the same lock under a 100ms lock_timeout (expect an ERROR below)"
docker exec "$C" psql -U postgres -d "$DB" \
  -c "SET lock_timeout='100ms';" -c "BEGIN;" \
  -c "LOCK TABLE $TABLE IN ACCESS EXCLUSIVE MODE;" \
  -c "ROLLBACK;" -c "SELECT relname FROM pg_class LIMIT 1;" > "$BLOG" 2>&1
cat "$BLOG"

# Let session A's sleep finish and its COMMIT land before the probe is stopped, so both sessions'
# full activity is captured. A real wait on a real job now: before #395 this was a bare `wait` with
# no host-side job in existence, so it returned instantly. Measured against the unfixed script: the
# whole run finished in 9.6 s against an 8 s hold, the probe was killed roughly 6 s before A
# committed, and the capture carried a commit event for B's pid and NONE for A's. It still produced
# the right verdict only because the `drop table` at the very end blocks on A's lock, supplying by
# accident the ordering this line is supposed to enforce -- and a retimed run would not.
if ! wait "$A_JOB"; then
  echo "warning: session A's psql exited non-zero; see $ALOG" >&2
fi

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

# --- assertions -----------------------------------------------------------------------------
#
# This script used to end by PRINTING what a reader should look for and exiting 0 regardless. That
# was honest while nothing ran it; it is not good enough now that CI does, because a demo that
# cannot fail gates nothing. The checks below are the same two observations the old prose named,
# plus the liveness witnesses without which every one of them is vacuous.
#
# WHY NOT "no lock event carries session B's pid". That is how the prose put it, and it is not
# available to this script: eBPF reports pids from the kernel's initial namespace and psql's
# pg_backend_pid() reports them from inside the container's, so the two never join (see
# bench/lock_view.py's header). The capture is discriminated on its SHAPE instead, which needs no
# pid correlation at all -- and every one of these values flips when the fix is reverted:
#
#                                 fixed      pre-fix (filter moved back onto on_lock)
#   lock events                   1          2   (A's real grant, plus B's fabricated one)
#   largest wait_ns               ~2e4       ~1.0e8  (the 100ms lock_timeout window, measured
#                                                    at 100488505 in the original proof run)
#   unmatched                     1          0   (the lost wait counted, versus stolen silently)
docker exec "$C" cat "$EVENTS" > "$CAP"
read -r n_lock max_wait a_commit unmatched dropped <<EOF
$(python3 - "$CAP" <<'PY'
import json, sys
recs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
tail = recs[-1] if recs and "dropped" in recs[-1] else {}
locks = [r for r in recs if r.get("kind") == "lock"]
commits = {r["pid"] for r in recs if r.get("kind") == "commit"}
# Session A is the only backend that can appear as a granted lock on the watched oid: B's request
# was aborted and must never be emitted at all. So locks[0]'s pid IS A's, whenever there is one.
a_pid = locks[0]["pid"] if locks else 0
print(len(locks),
      max((r["wait_ns"] for r in locks), default=0),
      "true" if a_pid and a_pid in commits else "false",
      tail.get("unmatched", -1),
      tail.get("dropped", -1))
PY
)
EOF

# A wait anywhere near the 100ms timeout is the fabricated grant's signature. A's real grant was
# uncontended and measured ~2e4 ns; the fabricated one carries the whole timeout window. 1ms sits
# three orders of magnitude clear of the first and two clear of the second.
if [ "$max_wait" -ge 1000000 ]; then near_timeout=true; else near_timeout=false; fi
if grep -q 'canceling statement due to lock timeout' "$BLOG"; then b_aborted=true; else b_aborted=false; fi

echo
echo "--- assertions ---"
# Liveness first: without these two, every assertion below is satisfied by a run in which nothing
# happened, which is the failure shape this whole repo is organised against.
check "session B's wait was actually aborted by lock_timeout" "$b_aborted" true
check "session A's commit is in the capture, so the probe outlived it" "$a_commit" true
check "exactly one lock event: A's real grant, and no fabricated second" "$n_lock" 1
check "no lock event carries a wait near the 100ms lock_timeout" "$near_timeout" false
check "the aborted wait was COUNTED against its own request" "$unmatched" 1
check "no events were dropped" "$dropped" 0

echo
if [ "$fail" = 0 ]; then echo "pairing demo: PASS"; else echo "pairing demo: FAIL"; fi
exit "$fail"
