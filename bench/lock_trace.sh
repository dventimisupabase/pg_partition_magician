#!/usr/bin/env bash
# Guard a maintenance tick's lock boundaries by OBSERVING them, not inferring them (issue #383).
# Run by CI (`./test.sh locktrace`). Linux-only; see docker-compose.yml's locktrace service.
#
# WHAT MAKES THIS DIFFERENT FROM bench/maintain_lock.sh. That guard proves the same property
# indirectly: a concurrent reader under a short lock_timeout either times out or does not. Cheap,
# portable, runs on a laptop -- and inference. It cannot see a lock it did not happen to collide
# with, and it cannot say WHICH boundary released the lock. That blind spot is not hypothetical:
# redesigning maintain_lock.sh for #347 left it passing while its own mutation regex never matched a
# real, unconditional commit boundary (#265, before FK-validate), and finding that took a full
# session of CALL + pg_sleep() + single-pg_locks-check archaeology, precisely because there was no
# continuous trace to read.
#
# pg-lock-tracer attaches uprobes to the running postgres binary and reports every lock acquire and
# release as it happens. So the claim here is not "a reader was not blocked" but the thing itself:
# mg_ret's ACCESS EXCLUSIVE was RELEASED, and a transaction COMMITTED, before ml's turn began.
#
# THE FIXTURE is maintain_lock.sh's, and deliberately so -- two managed tables swept by one
# maintain_all(), mg_ret first (its name sorts before ml, and pgpm.config is swept `order by
# parent_table`). mg_ret's retain DROPs take ACCESS EXCLUSIVE on its parent; ml's regrain copy is the
# long step that follows. For mg_ret's lock to survive into ml's turn, EVERY commit standing between
# them has to be missing: maintain()'s own internal boundaries, the easily-missed #265 one before
# FK-validate (unconditional every tick, with or without an incoming FK), and maintain_all()'s outer
# per-parent commit.
#
# It is much SMALLER than maintain_lock.sh's, though, and that is the point of tracing rather than
# probing. That guard needs MONO=6,000,000 so the regrain copy runs ~2.3 s -- a window wide enough
# for a reader probe to land inside repeatedly, because its unit of observation costs a whole
# lock_timeout. A trace has no such cost: the release either appears between the two anchors or it
# does not, at any fixture size. So this runs on 400k rows and takes well under a minute.
#
# THE ANCHORS, both chosen by reading real traces rather than guessed:
#
#   * mg_ret's PARENT oid, never a partition oid. retain DROPs the partition, so a partition's oid
#     stops resolving in pg_class the moment the thing under test succeeds. The parent's oid is
#     stable, and it is what a reader of `public.mg_ret` would actually block on.
#   * ml's PARENT oid, alone -- not "any ml-family relation". Measured: the parent has ZERO lock
#     events before mg_ret's sweep and 7 after, so it cleanly marks where ml's turn starts, with no
#     name-prefix matching and no dependence on a partition list that regrain is busy changing.
#
# THE ORDERING ASSERTION, on one traced tick, restricted to the backend that ran it: between the LAST
# AccessExclusiveLock grant on mg_ret's parent and the FIRST lock event on ml's parent, there must be
# (a) an AccessExclusiveLock UNgrant on mg_ret's parent -- the release itself -- and (b) at least one
# TRANSACTION_COMMIT, which is the boundary vocabulary #265 and #279 are written in. Measured on
# correct code: 4 releases and 7 commits sit in that interval.
#
# Four things about the tracer, each learned by getting it wrong:
#
#   1. Gate on `===> Ready to trace queries`, NEVER on `===> Attaching BPF probes`. init() prints the
#      latter BEFORE attach_probes() runs and before the perf buffer is open; only the former means
#      events are being delivered. Starting the tick on the earlier line loses the beginning of it.
#   2. PYTHONUNBUFFERED=1 is required. Redirected to a file, the tracer's status output is
#      block-buffered and the log sits at 0 bytes for as long as it takes to fill a block -- measured
#      at still-empty after 12 s, which makes the gate above look like a hang.
#   3. Events name themselves LOCK_GRANTED_LOCAL / LOCK_UNGRANTED / LOCK_UNGRANTED_LOCAL. Plain
#      LOCK_GRANTED (from GrantLock) fired ZERO times in any trace taken here, so a guard written
#      against that name would pass while observing nothing at all.
#   4. THE FILE IS NOT IN TIME ORDER. Events arrive through a per-CPU perf ring buffer and are
#      written in DELIVERY order, so a handful come out transposed. Measured on a real tick: 4
#      inversions in 101,185 events -- 0.004% -- and two of those four were the QUERY_BEGIN and
#      QUERY_END markers themselves, which moved maintain_all()'s QUERY_BEGIN from its true position
#      at index 47,589 to 100,401. Reading the file as written therefore computed a 326-event window
#      where the real one is 53,391, and put every lock event in the tick into the wrong statement.
#      So sort by `timestamp` before reasoning about order at all. Note how that failed: not with an
#      error, but with a window that was merely EMPTY of the things under test -- and it was the
#      liveness witnesses below, not the ordering assertion, that caught it. An ordering assertion
#      over an empty interval is vacuously true, and this guard would otherwise have reported the
#      property holding while measuring nothing whatsoever.
#
# AND THE LIVENESS WITNESSES, which matter more here than in any other guard in this directory. An
# ordering assertion is a claim about an interval; over an EMPTY interval it is vacuously true. A
# tick with nothing to drop takes no strong lock, produces no anchor, and would sail through. That
# is not hypothetical either -- it is exactly what happened during the spike, where a fixture
# exhausted by an earlier run produced zero AccessExclusive events and looked like lost capture. So
# the guard asserts, before it asserts any ordering: the tracer reached its ready line; the trace is
# non-empty and contains the tick's own query; both anchors were actually found; and pgpm.log shows
# the tick DID the work that takes the lock, by exact action name (`retain_drop`, `regrain_copy`,
# `obtain` -- never a prefix match, since non-success events are prefixed `skip_`/`fail_`).
#
# Usage: lock_trace.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
MONO=${MONO:-400000}          # rows in ml before conversion; the monolith covers them
BATCH=${BATCH:-200000}
SUB=${SUB:-100000}            # regrain sub-range: small enough that a copy tick happens at all
PGBIN=${PGBIN:-/usr/lib/postgresql/17/bin/postgres}
TRACE=/tmp/pgpm_lock_trace.json
TLOG=/tmp/pgpm_lock_trace.log
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
# capture and copies nothing, so there is no long step in it. Tracing that tick would observe no
# regrain work at all. mg_ret has nothing eligible yet, so this is a no-op for it.
q "call pgpm.maintain_all()" >/dev/null

# Now give mg_ret something to drop in the MEASURED tick: advance ITS frontier past its own oldest
# partition. retain() picks the oldest eligible first, so this is deterministic.
HIA=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.mg_ret'::regclass")
q "insert into public.mg_ret values ($((HIA-1)), 'advances mg_ret past its own oldest partition')" >/dev/null

# Clear the log so the work witnesses below are about the MEASURED tick alone. Without this,
# transmute's own initial obtain calls and the warm-up tick's entries satisfy them, and they pass on
# stale evidence -- the same vacuous shape the witnesses exist to catch.
q "delete from pgpm.log" >/dev/null

# The anchors, resolved from the catalog: parents only (see the header).
MG_OID=$(q "select 'public.mg_ret'::regclass::oid")
ML_OID=$(q "select 'public.ml'::regclass::oid")

# --- trace the measured tick -------------------------------------------------------------------
docker exec "$C" sh -c "rm -f $TRACE $TLOG"
docker exec -d -e PYTHONUNBUFFERED=1 "$C" sh -c \
  "pg_lock_tracer -x $PGBIN -j -t LOCK TRANSACTION QUERY -o $TRACE > $TLOG 2>&1"

# No -p filter: the tracer attaches uprobes to the BINARY, so every backend is traced and the tick's
# own backend does not have to exist yet -- which it must not, since attaching after the tick starts
# would miss its opening locks. The analysis below picks the tick's pid out of the trace itself.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$C" grep -q 'Ready to trace queries' "$TLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
check "the tracer attached and is delivering events" "$ready" "true"
if [ "$ready" != true ]; then
  echo "      --- tracer log ---"; docker exec "$C" cat "$TLOG" 2>&1 | sed 's/^/      /'
  docker exec "$C" pkill -INT -f pg_lock_tracer >/dev/null 2>&1
  exit 1
fi

# maintain_obtain() and maintain_all() are separate top-level statements (#347: separate cron jobs in
# production), run back to back in one session the way an operator's worst case would.
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "call pgpm.maintain_obtain('public.ml')" -c "call pgpm.maintain_all()" >/dev/null 2>&1

# SIGINT, then wait for the process to actually go: the tracer flushes its output on the way out, and
# reading the file while it is still draining would truncate the very tail this guard reasons about.
docker exec "$C" pkill -INT -f pg_lock_tracer >/dev/null 2>&1
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f pg_lock_tracer >/dev/null 2>&1 || break
  sleep 1
done

# --- analyse the trace -------------------------------------------------------------------------
# In the container, where python3 and the trace both already are. Emits KEY=VALUE lines so the
# assertions below stay readable bash, in the same shape as every other guard here.
eval "$(docker exec -i "$C" python3 - "$MG_OID" "$ML_OID" "$TRACE" <<'PY'
import json, sys

mg, ml, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

def emit(**kw):
    for k, v in kw.items():
        print(f"{k}={v}")

try:
    events = [json.loads(line) for line in open(path) if line.strip()]
except FileNotFoundError:
    emit(TRACE_EVENTS=0, TICK_FOUND="false", MG_GRANTS=0, ML_ANCHOR="false",
         RELEASE_BEFORE_ML="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

# In time order, which the file is NOT in (see point 4 in the header): the events come off a per-CPU
# perf buffer in delivery order, and the few transpositions that causes are enough to move a
# statement boundary tens of thousands of events away from where it belongs.
events.sort(key=lambda e: e["timestamp"])

# The tick's own backend, identified from the trace rather than passed in: the tracer is started
# before the session exists, so there is no pid to pass, and picking it out here means the guard
# never reasons over another backend's locks (autovacuum, the pg_cron launcher) by accident.
pids = [e["pid"] for e in events
        if e["event"] == "QUERY_BEGIN" and "maintain_all" in e.get("query", "")]
if not pids:
    emit(TRACE_EVENTS=len(events), TICK_FOUND="false", MG_GRANTS=0, ML_ANCHOR="false",
         RELEASE_BEFORE_ML="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

pid = pids[0]
own = [e for e in events if e["pid"] == pid]

# Restrict to the maintain_all() statement. A whole tick is ONE query -- one QUERY_BEGIN/QUERY_END
# pair with tens of thousands of events inside it -- so this window is the statement, not a step.
# It matters that maintain_obtain() is excluded: its own AccessExclusive grants on ml's parent would
# otherwise sit before mg_ret's sweep and make "ml's turn" look like it had already started.
start = next(i for i, e in enumerate(own)
             if e["event"] == "QUERY_BEGIN" and "maintain_all" in e.get("query", ""))
ends = [i for i, e in enumerate(own) if i > start and e["event"] == "QUERY_END"]
win = own[start:(ends[0] + 1) if ends else len(own)]

grants = [i for i, e in enumerate(win)
          if e.get("oid") == mg and e.get("lock_type") == "AccessExclusiveLock"
          and e["event"] == "LOCK_GRANTED_LOCAL"]
ml_hits = [i for i, e in enumerate(win) if e.get("oid") == ml]

if not grants or not ml_hits:
    emit(TRACE_EVENTS=len(events), TICK_FOUND="true", MG_GRANTS=len(grants),
         ML_ANCHOR=str(bool(ml_hits)).lower(),
         RELEASE_BEFORE_ML="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

# The interval under test: from the LAST strong-lock grant on mg_ret (retain holds it across every
# drop in its step, releasing once at that step's commit) to the FIRST time ml's parent is touched.
last_grant = grants[-1]
ml_start = [i for i in ml_hits if i > last_grant]
if not ml_start:
    emit(TRACE_EVENTS=len(events), TICK_FOUND="true", MG_GRANTS=len(grants), ML_ANCHOR="false",
         RELEASE_BEFORE_ML="false", COMMIT_BEFORE_ML="false")
    sys.exit(0)

lo, hi = last_grant, ml_start[0]
between = win[lo:hi]
releases = sum(1 for e in between
               if e.get("oid") == mg and e.get("lock_type") == "AccessExclusiveLock"
               and e["event"] in ("LOCK_UNGRANTED", "LOCK_UNGRANTED_LOCAL"))
commits = sum(1 for e in between if e["event"] == "TRANSACTION_COMMIT")

emit(TRACE_EVENTS=len(events), TICK_FOUND="true", MG_GRANTS=len(grants), ML_ANCHOR="true",
     RELEASES_BETWEEN=releases, COMMITS_BETWEEN=commits,
     RELEASE_BEFORE_ML=str(releases > 0).lower(),
     COMMIT_BEFORE_ML=str(commits > 0).lower())
PY
)"

# --- the witnesses that the ordering assertion is about a non-empty interval --------------------
check "the trace is non-empty"                       "$([ "${TRACE_EVENTS:-0}" -gt 0 ] && echo true || echo false)" "true"
check "the traced tick is the one under test"        "${TICK_FOUND:-false}" "true"
check "mg_ret took ACCESS EXCLUSIVE in the tick"     "$([ "${MG_GRANTS:-0}" -gt 0 ] && echo true || echo false)" "true"
check "ml's turn is visible in the same tick"        "${ML_ANCHOR:-false}" "true"
# A tick starved of its locks logs skip_retain/skip_obtain, takes no strong lock, and would leave the
# interval above empty. Exact action values, never a prefix: non-success events are prefixed
# (skip_drain, fail_retain_drop), precisely so `retain%` cannot match a deferral.
check "the tick did the work that takes the lock (retain)" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.mg_ret'::regclass and action = 'retain_drop'")" "true"
check "and regrained ml in the same tick" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action = 'regrain_copy'")" "true"
check "and obtained for ml" \
      "$(q "select (count(*) > 0)::text from pgpm.log
             where parent_table='public.ml'::regclass and action = 'obtain'")" "true"

# --- the property itself -----------------------------------------------------------------------
check "mg_ret's ACCESS EXCLUSIVE is released before ml's turn" "${RELEASE_BEFORE_ML:-false}" "true"
check "and a transaction commits in between"                   "${COMMIT_BEFORE_ML:-false}" "true"
printf '      observed: %s release(s) and %s commit(s) between mg_ret'"'"'s last ACCESS EXCLUSIVE grant and ml'"'"'s first lock\n' \
       "${RELEASES_BETWEEN:-0}" "${COMMITS_BETWEEN:-0}"

exit "$fail"
