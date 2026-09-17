#!/usr/bin/env bash
# Render a lock sequence for human review (issue #392). NOT a guard: it asserts nothing about pgpm's
# behaviour and blocks no merge. bench/lock_trace.sh is the guard; this is the picture.
#
# Usage: lock_view.sh <container> <db> <relations> <sql> [run-name]
#   lock_view.sh pgpm_test-locktrace mydb 'public.mg_ret,public.ml' "call pgpm.maintain_all()"
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; RELS="${3:?relations}"; SQL="${4:?sql}"
RUN="${5:-run}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/lockview-$RUN-$(date +%Y%m%d-%H%M%S)"
EVENTS=/tmp/pgpm_lock_view.jsonl
PLOG=/tmp/pgpm_lock_view.log

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }

# Asserted up front so that losing it is legible, rather than a BCC compile error a hundred lines
# into a log.
if ! docker exec "$C" python3 -c 'import bcc' 2>/dev/null; then
  echo "error: $C has no bcc. Start the locktrace service:" >&2
  echo "  docker compose --profile locktrace up -d" >&2
  exit 1
fi

mkdir -p "$OUT"
OIDS=$(q "select string_agg(c.oid::text, ',') from unnest(string_to_array('$RELS', ','))
          r join pg_class c on c.oid = trim(r)::regclass")
[ -n "$OIDS" ] || { echo "error: none of '$RELS' resolved" >&2; exit 1; }

# Prime enlistment (issue #392 review, finding 1). bench/lock_view.py enlists a backend into
# `watched` only once it touches one of the target oids, so any lock that SAME backend took
# EARLIER in the traced statement is silently missing -- `LOCK other; LOCK target;` in one
# statement loses `other` outright, with no refusal anywhere to catch it. The first enlisted
# relation is the one this harness can reach ahead of the traced SQL: a trivial `limit 0` touch
# of it, issued as its own psql `-c` immediately before `$SQL` and run via the same `docker exec
# psql` invocation (one backend, one pid, still separate implicit transactions), enlists the
# backend before the traced statement runs anything at all.
FIRST_REL="$(printf '%s' "$RELS" | cut -d, -f1 | xargs)"
PRIMER="select 1 from $FIRST_REL limit 0"

# The name map, snapshotted DURING the window. The three folds are SQL joins because that is where
# they belong: index to its table, toast to its table, partition to its managed parent. Resolving
# any of this afterwards fails for the relations most worth seeing, since retain drops them.
#
# The query lives in bench/sql/lockview_names.sql, not inlined here, so
# bench/lock_view_names_scope_demo.sh can run the EXACT SQL this harness runs against a synthetic
# fixture instead of a hand-copied duplicate that could drift. See that file's own header for the
# two-hop fold and the schema-scoped managed_parent join (issue #392 review, finding 2): two managed
# parents sharing a bare relname in different schemas used to fold their children onto whichever
# parent's row happened to read last, nondeterministically, because the join matched on bare child
# name alone.
names_snapshot() {
  docker exec "$C" psql -U postgres -d "$DB" -qtA -F, -f /repo/bench/sql/lockview_names.sql
}

# Checked, not fired-and-forgotten (issue #392 review, fix 1): a failing snapshot under
# `set -uo pipefail` (no `-e`) would otherwise truncate the CSV and let the run continue.
# _read_names then returns {} without complaint, every relation falls through to the "created
# during the window" fallback, and the renderer produces a one-row figure that PASSES all four
# refusals -- wrong, but not caught by any of them, unlike a failed traced statement (which at
# least usually trips "empty" or "strong" downstream). This aborts rather than warns, because a
# capture whose names are missing cannot produce a correct figure at all, not just a degraded
# one; nothing has been started yet at this point, so there is nothing to unwind.
if ! names_snapshot > "$OUT/names.before.csv" 2>"$OUT/names.before.stderr"; then
  echo "error: the BEFORE names snapshot failed; see $OUT/names.before.stderr" >&2
  echo "       aborting rather than warning: every relation would silently fall back to" >&2
  echo "       'created during the window' and still render a one-row figure that passes" >&2
  echo "       every refusal, which is worse than no figure at all" >&2
  exit 1
fi
[ -s "$OUT/names.before.stderr" ] || rm -f "$OUT/names.before.stderr"

docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
docker exec -d "$C" sh -c "python3 /repo/bench/lock_view.py $OIDS $EVENTS > $PLOG 2>&1"

# Gate on READY, never on anything printed earlier: it is the only line that means the uprobes are
# attached AND the ring buffer is open.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "error: probe never became READY" >&2
  docker exec "$C" cat "$PLOG" >&2
  docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
  exit 1
fi

# The probe's bpf_ktime_get_ns() and the host's CLOCK_MONOTONIC are the SAME clock domain (same
# kernel), verified on the design spike. Clocks cross the container boundary; pids do not.
#
# Honesty about where the primer lands (finding 1): T_BEGIN is recorded here, before the ONE
# combined `docker exec` below that runs the primer and `$SQL` back to back over the same
# connection. There is no point at which this script can record a timestamp BETWEEN the primer
# and `$SQL` without splitting them into separate psql invocations, which would give them
# separate backends and defeat the whole point of priming. So the primer's own AccessShare mark
# lands INSIDE the shaded [T_BEGIN, T_END] band on the figure, not before it, even though it is
# not part of the traced statement's own work. bench/README.md says this plainly: the first
# AccessShare mark on the first enlisted relation is the primer, not the traced statement.
T_BEGIN=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
# Kept and checked, not discarded: a failed or partially-executed traced statement still lets
# the capture and render proceed (a near-empty capture usually trips the "empty"/"strong"
# refusal downstream), but that refusal reads as "the probe saw nothing" when the real cause
# was the SQL itself. Warning here, with the real error alongside the capture, means a wrong
# picture never has to be debugged as though it were a probe defect.
#
# $PRIMER runs as its OWN `-c`, ahead of `$SQL`, in this same invocation -- one backend, primed
# before the traced statement touches anything. "Only when it is safe and possible" (finding 1):
# if the first enlisted relation cannot be selected from (dropped mid-run, no SELECT privilege,
# whatever), the primer's `-c` fails on its own and psql -- run without ON_ERROR_STOP, exactly as
# every other multi-statement invocation in this script -- reports that error and moves on to the
# NEXT `-c`; the exit status checked below reflects only the LAST command, so a primer failure
# never surfaces as "the traced statement exited non-zero" (verified: a failing first `-c`
# followed by a succeeding second one exits 0). `sql.stderr` may therefore carry a harmless
# primer error alongside, or instead of, a real one from `$SQL` itself; only the exit status says
# which happened.
if ! docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$PRIMER" -c "$SQL" >/dev/null 2>"$OUT/sql.stderr"; then
  echo "warning: the traced statement exited non-zero; see $OUT/sql.stderr" >&2
  echo "         the capture below may be empty or partial for that reason, not because the probe failed" >&2
fi
[ -s "$OUT/sql.stderr" ] || rm -f "$OUT/sql.stderr"
T_END=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')

# SIGINT then WAIT: the drop count is written on the way out, and reading early truncates the very
# record that says whether anything was lost.
docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
probe_exited=false
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f lock_view.py >/dev/null 2>&1 || { probe_exited=true; break; }
  sleep 1
done
if [ "$probe_exited" != true ]; then
  echo "warning: the probe did not exit within 30s of SIGINT" >&2
  echo "         the capture may be truncated and the drop count may be missing; expect the" >&2
  echo "         downstream 'drain' refusal if so" >&2
fi

# Same discipline as the BEFORE snapshot above, checked rather than fired-and-forgotten. The
# probe has already stopped and the raw capture still needs to come out of the container, so on
# failure this still copies events.jsonl (the raw capture is not itself wrong, only its name
# resolution) before aborting ahead of meta.json and the render, which would otherwise silently
# produce a wrong figure from an empty or truncated names.after.csv.
if ! names_snapshot > "$OUT/names.after.csv" 2>"$OUT/names.after.stderr"; then
  docker cp "$C:$EVENTS" "$OUT/events.jsonl" >/dev/null
  echo "error: the AFTER names snapshot failed; see $OUT/names.after.stderr" >&2
  echo "       the raw capture (events.jsonl) was still copied into $OUT for a later, manual" >&2
  echo "       re-render once the failure is understood; rendering now would silently produce" >&2
  echo "       a wrong figure, since every relation would fall back to 'created during the" >&2
  echo "       window' and still pass every refusal" >&2
  exit 1
fi
[ -s "$OUT/names.after.stderr" ] || rm -f "$OUT/names.after.stderr"
docker cp "$C:$EVENTS" "$OUT/events.jsonl" >/dev/null

python3 - "$OUT" "$RUN" "$SQL" "$RELS" "$OIDS" "$T_BEGIN" "$T_END" <<'PY'
import json, subprocess, sys
out, run, sql, rels, oids, t0, t1 = sys.argv[1:8]
sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                     capture_output=True, text=True).stdout.strip()
open(f"{out}/meta.json", "w").write(json.dumps({
    "run": run, "sql": sql, "enlist": rels.split(","),
    "enlist_oids": [int(o) for o in oids.split(",")],
    "t_begin": int(t0), "t_end": int(t1), "git_sha": sha,
    # Names which probe wrote this capture's events: bench/lock_view.py writes `ts` at the
    # GRANT (it pairs request and grant via a uretprobe); bench/lock_probe.py, the CI guard's
    # probe, writes `ts` at the REQUEST and never wrote a producer key at all. Recorded so
    # plot_lock_view.py's `render` can stamp the correct timestamp semantics on the figure
    # instead of assuming grant time for every capture it loads (issue #392 review, fix 7 and
    # finding 3 -- the original comment here claimed the loader already acted on this key; it
    # did not, until finding 3's fix).
    "producer": "lock_view.py",
}, indent=2) + "\n")
PY

# plot_lock_view.py imports matplotlib, which the system python3 does not have (PEP 668 blocks
# `pip install matplotlib` there); run it under the venv this repo keeps for exactly this
# (Ruling 8a), never the system interpreter.
"$ROOT/.venv-lockview/bin/python" "$ROOT/bench/plot_lock_view.py" "$OUT" || exit 1
echo "wrote $OUT/lock-view.png and .svg"
