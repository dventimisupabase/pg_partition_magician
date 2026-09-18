#!/usr/bin/env bash
# Guard a maintenance tick's lock boundaries by OBSERVING them, not inferring them (issue #383).
# Run by CI (`./test.sh locktrace`). Linux-only; see docker-compose.yml's locktrace service.
#
# WHAT MAKES THIS DIFFERENT FROM bench/maintain_lock.sh. That guard proves the same property
# indirectly: a concurrent reader under a short lock_timeout either times out or does not. Cheap,
# portable, runs on a laptop -- and inference. It cannot see a lock it did not happen to collide
# with, and it cannot say WHICH boundary released the lock. That blind spot is not hypothetical:
# redesigning maintain_lock.sh for #347 left it passing while its own mutation regex never matched a
# real, unconditional commit boundary (#265, before FK-validate).
#
# THE INSTRUMENT is bench/lock_probe.py: a purpose-built eBPF probe on two functions, filtering in
# the kernel. It replaced pg-lock-tracer, which this guard used first and which proved unsound as a
# CI foundation for reasons worth not re-learning (#389): it emitted every lock event for the whole
# server through a PER-CPU perf buffer, which delivers out of order across CPUs (4 inversions in
# 101,185 events moved a statement marker 53,000 positions and silently shrank the window under test
# to nothing), and it opened that buffer with no lost_cb, so overflow discarded events in SILENCE
# (4,150 lost in one run, the guard reporting a lock as never released while the commits in the same
# interval proved otherwise). Filtering in the kernel turns ~120,000 events per tick into dozens,
# and BPF_RINGBUF gives one ordered stream plus a drop count the probe reports itself.
#
# THE FIXTURE is maintain_lock.sh's -- two managed tables swept by one maintain_all(), mg_ret first
# (its name sorts before ml, and pgpm.config is swept `order by parent_table`). mg_ret's retain DROPs
# take ACCESS EXCLUSIVE on its parent; ml's regrain copy is the long step that follows. For mg_ret's
# lock to survive into ml's turn, EVERY commit standing between them has to be missing: maintain()'s
# own internal boundaries, the easily-missed #265 one before FK-validate (unconditional every tick,
# with or without an incoming FK), and maintain_all()'s outer per-parent commit.
#
# It is much SMALLER than maintain_lock.sh's, and that is the point of tracing rather than probing.
# That guard needs MONO=6,000,000 so the regrain copy runs ~2.3 s -- a window wide enough for a
# reader probe to land inside repeatedly, because its unit of observation costs a whole lock_timeout.
# A trace has no such cost: the commit either falls between the two anchors or it does not.
#
# THE ANCHORS, both parent oids, never partition oids. retain DROPs the partition, so a partition's
# oid stops resolving the moment the thing under test succeeds; a parent's oid is stable, and it is
# what a reader of the table would actually block on.
#
# THE ASSERTION: between the LAST AccessExclusiveLock on mg_ret's parent and the FIRST lock of any
# mode on ml's parent, at least one TRANSACTION_COMMIT occurs in the same backend. That is the
# boundary vocabulary #265 and #279 are written in, and what #383 specified. A commit releases the
# lock, so this is the property.
#
# REQUESTS, NOT GRANTS (issue #393). bench/lock_probe.py attaches with attach_uprobe, which fires at
# function ENTRY, so every `kind: "lock"` record is a lock REQUEST, and the variables and labels below
# say so. The guard's conclusions are unaffected, and the argument is recorded here so the next reader
# does not have to re-derive it: under the request reading BOTH endpoints of the interval move
# earlier, but the interval contains exactly the SAME commits, because a backend cannot commit while
# it is blocked on a lock it has itself requested. A commit between mg_ret's request and its grant is
# impossible (the backend is waiting), and a commit between ml's request and its grant is likewise
# impossible -- and the request-based endpoint excludes that window anyway, so it cannot admit a
# spurious commit either. Neither a false pass nor a false fail is reachable through the distinction.
# On this fixture the two readings are microseconds apart regardless, it being single-backend and
# uncontended.
#
# Under CONTENTION the distinction is the whole signal: the distance between request and grant IS the
# wait. bench/lock_view.py adds an attach_uretprobe precisely so that span is observed rather than
# inferred, and shipping that beside a guard whose variables called a request a grant invited the
# misreading this repo keeps paying for.
#
# The RELEASE is deliberately not asserted, and not even probed. UnGrantLock and RemoveLocalLock take
# pointers to structs, so recovering a relation oid from them means reading fields at offsets that
# shift between PostgreSQL versions -- the fragility this instrument exists to avoid.
# LockRelationOid(Oid, LOCKMODE) passes scalars, which is why it is the one lock probe used here.
#
# maintain_obtain() runs BEFORE tracing starts, on purpose. It takes ACCESS EXCLUSIVE on ml's parent
# to create partitions, which would otherwise land in the traced stream ahead of mg_ret's sweep and
# make "ml's turn" look like it had already begun. The old pg-lock-tracer version excluded it with a
# query-boundary probe; not probing queries at all is simpler and needs no extra uprobe.
#
# THE LIVENESS WITNESSES matter more here than in any other guard in this directory. An ordering
# assertion is a claim about an interval, and over an EMPTY interval it is vacuously true. A tick
# with nothing to drop takes no strong lock, produces no anchor, and would sail through. So the guard
# asserts, before it asserts any ordering: the probe attached and is delivering; both anchors were
# found; NO events were dropped (the probe counts that itself, in the kernel, at the instant of the
# event); and pgpm.log shows the tick DID the work that takes the lock, by exact action name
# (retain_drop, regrain_copy -- never a prefix, since non-success events are prefixed skip_/fail_).
#
# Usage: lock_trace.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
MONO=${MONO:-400000}          # rows in ml before conversion; the monolith covers them
BATCH=${BATCH:-200000}
SUB=${SUB:-100000}            # regrain sub-range: small enough that a copy tick happens at all
EVENTS=/tmp/pgpm_lock_probe.jsonl
PLOG=/tmp/pgpm_lock_probe.log
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-56s %s\n' "$1" "$2"
  else printf 'FAIL  %-56s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

# --- mg_ret: the retain-drop table, swept FIRST. Nothing is retention-eligible yet; its frontier is
# advanced only after the warm-up tick below, so the warm-up does not consume it.
q "create table public.mg_ret (id bigint primary key, v text)" >/dev/null
q "insert into public.mg_ret select g, 'x' from generate_series(1,100) g" >/dev/null
q "call pgpm.transmute('public.mg_ret','id',100000::bigint, p_retain => 100000::bigint, p_paused => false)" >/dev/null

# --- ml: the regrain table, swept second.
q "create table public.ml (id bigint primary key, v text)" >/dev/null
q "insert into public.ml select g, repeat('x',60) from generate_series(1,$MONO) g" >/dev/null
q "call pgpm.transmute('public.ml','id', $MONO::bigint, p_paused => false)" >/dev/null
# Advance the frontier to the TOP of the grid: this freezes the monolith (so auto-regrain has a
# target at all) and gives maintain_obtain() partitions to create. The ceiling is read back rather
# than assumed, since transmute builds the grid during the cutover.
HI=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ml'::regclass")
q "insert into public.ml values ($((HI-1)), 'advances the frontier to the grid ceiling')" >/dev/null
q "vacuum analyze public.ml" >/dev/null
q "update pgpm.config set regrain_batch=$BATCH where parent_table='public.ml'::regclass" >/dev/null
q "select pgpm.set_regrain('public.ml', '$SUB')" >/dev/null

# One warm-up tick over BOTH tables. A regrain's FIRST tick returns 'prepared': it installs change
# capture and copies nothing, so there is no long step in it. mg_ret has nothing eligible yet, so
# this is a no-op for it.
q "call pgpm.maintain_all()" >/dev/null

# Now give mg_ret something to drop in the MEASURED tick: advance ITS frontier past its own oldest
# partition. retain() picks the oldest eligible first, so this is deterministic.
HIA=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.mg_ret'::regclass")
q "insert into public.mg_ret values ($((HIA-1)), 'advances mg_ret past its own oldest partition')" >/dev/null

# obtain BEFORE the probe starts (see the header): its ACCESS EXCLUSIVE on ml's parent must not be in
# the traced stream, or ml's turn appears to start before mg_ret's sweep.
q "call pgpm.maintain_obtain('public.ml')" >/dev/null

# Clear the log so the work witnesses below are about the MEASURED tick alone. Without this,
# transmute's own initial obtain calls and the warm-up tick's entries satisfy them, and they pass on
# stale evidence -- the same vacuous shape the witnesses exist to catch.
q "delete from pgpm.log" >/dev/null

MG_OID=$(q "select 'public.mg_ret'::regclass::oid")
ML_OID=$(q "select 'public.ml'::regclass::oid")

# --- trace the measured tick -------------------------------------------------------------------
docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
docker exec -d "$C" sh -c \
  "python3 /repo/bench/lock_probe.py $MG_OID $ML_OID $EVENTS > $PLOG 2>&1"

# Gate on READY, which the probe prints only once the uprobes are attached AND the ring buffer is
# open. Starting the tick earlier would lose its opening locks.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
check "the probe attached and is delivering events" "$ready" "true"
if [ "$ready" != true ]; then
  echo "      --- probe log ---"; docker exec "$C" cat "$PLOG" 2>&1 | sed 's/^/      /'
  docker exec "$C" pkill -INT -f lock_probe.py >/dev/null 2>&1
  exit 1
fi

# The uprobes attach to the BINARY, so the probe sees matching locks from EVERY backend on the server
# and the analysis below must not mix them: autovacuum touching ml would end the measured interval
# early and fail a healthy run, and another session's strong lock plus commit could supply the commit
# this guard looks for while the tick under test held its lock straight through.
#
# The backend is identified FROM THE TRACE rather than passed in, because pg_backend_pid() cannot be
# used for this. It reports the pid inside the CONTAINER's namespace while eBPF reports the initial
# namespace -- measured on this fixture: 145 versus 71504 for the same backend -- so scoping by it
# matches nothing at all, which is exactly how the first attempt at this failed.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "call pgpm.maintain_all()" >/dev/null 2>&1

# SIGINT, then wait for the process to go: the probe drains the buffer and writes its drop count on
# the way out, and reading the file while it is still draining would truncate the very tail that
# says whether anything was lost.
docker exec "$C" pkill -INT -f lock_probe.py >/dev/null 2>&1
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f lock_probe.py >/dev/null 2>&1 || break
  sleep 1
done

# --- analyse ------------------------------------------------------------------------------------
# Dozens of records, already in order, so this is a short linear scan rather than the sort-and-window
# machinery the old firehose needed.
eval "$(docker exec -i "$C" python3 - "$MG_OID" "$ML_OID" "$EVENTS" <<'PY'
import json, sys

mg, ml, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ACCESS_EXCLUSIVE = 8

def emit(**kw):
    for k, v in kw.items():
        print(f"{k}={v}")

try:
    records = [json.loads(line) for line in open(path) if line.strip()]
except FileNotFoundError:
    emit(EVENT_COUNT=0, DROPPED=-1, MG_REQUESTS=0, ML_ANCHOR="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

dropped = next((r["dropped"] for r in records if "dropped" in r), -1)
events = [r for r in records if "kind" in r]

requests = [i for i, e in enumerate(events)
          if e["kind"] == "lock" and e["oid"] == mg and e["mode"] == ACCESS_EXCLUSIVE]
if not requests:
    emit(EVENT_COUNT=len(events), DROPPED=dropped, MG_REQUESTS=0, MG_BACKENDS=0,
         ML_ANCHOR="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

# The backend under test, taken from the trace: whoever REQUESTED mg_ret's strong lock. How many
# DISTINCT backends did so is reported alongside, and asserted to be one -- if a second session had
# also requested it, this anchor could be someone else's and the interval would splice two sessions
# together, which is the direction that PASSES and so the one worth checking rather than assuming.
backends = {events[i]["pid"] for i in requests}
last_request = requests[-1]
tick_pid = events[last_request]["pid"]

# From that LAST strong-lock REQUEST (retain holds the lock across every drop in its step, releasing
# once at that step's commit) to the FIRST time the SAME backend touches ml's parent at all.
ml_start = [i for i, e in enumerate(events)
            if i > last_request and e["pid"] == tick_pid
            and e["kind"] == "lock" and e["oid"] == ml]
if not ml_start:
    emit(EVENT_COUNT=len(events), DROPPED=dropped, MG_REQUESTS=len(requests),
         MG_BACKENDS=len(backends), ML_ANCHOR="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

between = events[last_request:ml_start[0]]
commits = sum(1 for e in between if e["kind"] == "commit" and e["pid"] == tick_pid)

emit(EVENT_COUNT=len(events), DROPPED=dropped, MG_REQUESTS=len(requests),
     MG_BACKENDS=len(backends), ML_ANCHOR="true",
     COMMITS_BETWEEN=commits, COMMIT_BEFORE_ML=str(commits > 0).lower())
PY
)"

# --- the witnesses that the ordering assertion is about a non-empty interval --------------------
check "the probe captured events"                 "$([ "${EVENT_COUNT:-0}" -gt 0 ] && echo true || echo false)" "true"
check "mg_ret requested ACCESS EXCLUSIVE in the tick" "$([ "${MG_REQUESTS:-0}" -gt 0 ] && echo true || echo false)" "true"
# The anchor identifies the backend under test, so a second backend requesting mg_ret's strong lock in
# the same window would let the interval splice two sessions together -- and that is the direction
# that PASSES, since the other session would supply the commit. Asserted, not assumed.
check "exactly one backend requested mg_ret's strong lock" "${MG_BACKENDS:-0}" "1"
check "ml's turn is visible in the same tick"     "${ML_ANCHOR:-false}" "true"
# Counted in the kernel, at the instant of the event, by the probe itself. Every assertion here is a
# claim about which events are present, so a stream with holes is not evidence of anything -- and
# unlike the tool this replaced, a hole cannot go unreported.
check "no events were dropped"                    "${DROPPED:--1}" "0"
# A tick starved of its locks logs skip_retain, takes no strong lock, and would leave the interval
# above empty. Exact action values, never a prefix: non-success events are prefixed (skip_drain,
# fail_retain_drop), precisely so `retain%` cannot match a deferral.
check "the tick did the work that takes the lock (retain)" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.mg_ret'::regclass and action = 'retain_drop'")" "true"
check "and regrained ml in the same tick" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action = 'regrain_copy'")" "true"

# --- the property itself -----------------------------------------------------------------------
check "a transaction commits between mg_ret's lock and ml's turn" "${COMMIT_BEFORE_ML:-false}" "true"
printf '      observed: %s event(s) captured, %s commit(s) between mg_ret'"'"'s last ACCESS EXCLUSIVE request and ml'"'"'s first lock\n' \
       "${EVENT_COUNT:-0}" "${COMMITS_BETWEEN:-0}"

exit "$fail"
