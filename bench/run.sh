#!/usr/bin/env bash
# At-scale load test for pg_partition_magician.
#
# pgpm is self-driving: you call adopt() once and pgpm's own pg_cron maintenance
# premakes + drains the default autonomously, inside the database. So this harness only
# (1) generates the bulk data SERVER-SIDE, (2) drives an ambient OLTP workload that has
# nothing to do with pgpm, (3) triggers the conversion once (adopt + schedule
# pgpm.maintenance) and marks the phase boundaries, and (4) writes a report. It never
# drives drain_step/premake itself; the conversion runs server-side.
#
# The SYSTEM metrics (WAL, checkpoints, pg_stat_io, wait/lock events, table sizes) are
# pg_flight_recorder's job -- it records them continuously and server-side, and the report
# slices its time-series by the recorded phase boundaries. The harness measures only what
# pgfr can't: the ambient workload's CLIENT-side throughput/latency (pgbench), the
# workload's per-phase server-side statement latency (a scoped pg_stat_statements reset),
# and pgpm's own conversion progress (pgpm.log) -- which is also how it knows when to stop.
#
# Everything is parameterised by env vars (see bench/README.md). The connection
# string is read from PGHOST/PGUSER/... or a single BENCH_DSN; it is NEVER echoed.
set -euo pipefail

# ---- config (override via env) ---------------------------------------------
PSQL="${PSQL:-psql}"
PGBENCH="${PGBENCH:-pgbench}"
BENCH_DSN="${BENCH_DSN:-}"                  # libpq conninfo/URI; if empty, use PG* env
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCH_DIR="$REPO_ROOT/bench"
RESULTS="${RESULTS:-$BENCH_DIR/results}"

BENCH_ROWS="${BENCH_ROWS:-300000000}"       # target rows in bench.events (~120GB at ~400B/row)
BENCH_MONTHS="${BENCH_MONTHS:-12}"          # spread history across this many months
BENCH_CHUNK="${BENCH_CHUNK:-2000000}"       # generator commit chunk
BENCH_GEN_JOBS="${BENCH_GEN_JOBS:-1}"       # parallel generator sessions (one INSERT..SELECT is single-core; fan out to use all cores)
BENCH_PREFREEZE="${BENCH_PREFREEZE:-0}"     # 1 = VACUUM(FREEZE,ANALYZE) after generation so the post-bulk-load
                                            #     freeze/hint-bit WAL settles BEFORE measuring (gentle arm: keeps the
                                            #     load aftermath out of the window so windowed I/O reflects the drain)
BENCH_INTERVAL="${BENCH_INTERVAL:-1 month}" # partition width
BENCH_PREMAKE="${BENCH_PREMAKE:-3}"

BENCH_CLIENTS="${BENCH_CLIENTS:-16}"        # pgbench concurrent clients
BENCH_JOBS="${BENCH_JOBS:-4}"               # pgbench worker threads
BENCH_OPS="${BENCH_OPS:-50}"                # server-side ops per workload_step call
BENCH_PHASE_SECS="${BENCH_PHASE_SECS:-120}" # per-phase load duration (baseline/post)
BENCH_ADOPT_WARM="${BENCH_ADOPT_WARM:-15}"  # load lead-in before firing adopt
BENCH_MAX_FAIL_PCT="${BENCH_MAX_FAIL_PCT:-5}"  # abort if baseline workload exceeds this failure % (mis-calibrated BENCH_OPS)

BENCH_DRAIN_BATCH="${BENCH_DRAIN_BATCH:-20000}"  # rows per drain_step (configured on adopt; pgpm uses it)
BENCH_DRAIN_MAX_SECS="${BENCH_DRAIN_MAX_SECS:-3600}"  # safety cap on the observation window
BENCH_MAINT_INTERVAL="${BENCH_MAINT_INTERVAL:-5 seconds}"  # pg_cron schedule for pgpm.maintenance (pgpm self-drives the drain)
BENCH_OBSERVE_INTERVAL="${BENCH_OBSERVE_INTERVAL:-15}"     # how often (s) the harness samples while pgpm drains
BENCH_DRAIN_IDLE_SECS="${BENCH_DRAIN_IDLE_SECS:-120}"      # drain is "settled" after this long with no pgpm drain activity

# How the convert phase decides it's done observing:
#   settle  -- run until pgpm fully drains the closed tail (the aggressive/"stress" arm: drive the
#              drain hard so it completes within the run, then confirm it settled). Default.
#   window  -- the GENTLE/steady-state arm: a gentle drain on a large table never finishes inside a
#              benchmark window, and it doesn't need to. Warm up until the drain is steadily running,
#              then measure the workload for a fixed window and compare it to baseline -- the question
#              is "is the drain unnoticeable?", not "is it done yet?". Convert metrics are restricted
#              to the measurement window (the one-time adopt cutover is excluded by the warm-up).
BENCH_OBSERVE_MODE="${BENCH_OBSERVE_MODE:-settle}"          # settle | window
BENCH_CONVERT_WARMUP_SECS="${BENCH_CONVERT_WARMUP_SECS:-30}"  # window mode: let the drain reach steady state before measuring
BENCH_CONVERT_WINDOW_SECS="${BENCH_CONVERT_WINDOW_SECS:-300}" # window mode: measure the workload for this long

# Ambient-surge injection (demonstrates adaptive feathering yielding to a write spike). During the
# convert observe phase, BENCH_SURGE_AFTER_SECS in, launch a write-heavy pgbench burst for
# BENCH_SURGE_SECS, then stop it -- the "Monday morning everybody logs in" moment. The drain_budget
# trace in drain.progress.csv should dip while the surge is live and recover after. Write-heavy on
# purpose: the controller senses WAL, and the drain dominates WAL, so only a WAL-heavy surge moves the
# signal enough to trigger a clean backoff (a read/CPU-heavy surge would contend without raising WAL).
BENCH_SURGE_CLIENTS="${BENCH_SURGE_CLIENTS:-0}"      # 0 = no surge; >0 = extra write-heavy clients
BENCH_SURGE_AFTER_SECS="${BENCH_SURGE_AFTER_SECS:-180}"  # seconds into the observe phase to start the surge
BENCH_SURGE_SECS="${BENCH_SURGE_SECS:-180}"         # how long the surge lasts
BENCH_SURGE_ROWS="${BENCH_SURGE_ROWS:-500}"         # rows inserted per surge call (WAL per round-trip)

BENCH_PGFR="${BENCH_PGFR:-0}"               # 1 = wire in pg_flight_recorder (best-effort; needs elevated privs, PG15-17)
BENCH_PGFR_DIR="${BENCH_PGFR_DIR:-$BENCH_DIR/vendor/pg_flight_recorder}"  # pgfr checkout (pgfr_record + pgfr_analyze)
BENCH_SKIP_GENERATE="${BENCH_SKIP_GENERATE:-0}"  # 1 = data already loaded, skip 00/10
BENCH_DEFER_INDEX="${BENCH_DEFER_INDEX:-0}"      # 1 = drop the secondary index during bulk load, rebuild after (much faster at scale)

# TCP keepalives on every connection (libpq defaults them OFF). Synchronous server-side calls
# sit idle ON THE WIRE while the backend works -- adopt's cutover (metadata-only),
# the bulk generators, the convert-phase pgbench between rows. Over a NAT'd
# path (e.g. Tailscale to a managed endpoint) an idle flow gets reaped, killing the call mid-way
# (observed: "server closed the connection unexpectedly" during the ~17s build_pk call).
# keepalives_idle MUST be SHORTER than those calls -- a probe has to fire DURING them to keep
# the NAT/proxy mapping warm; a longer idle (e.g. 30s) means a sub-30s call gets zero probes and
# is reaped. So probe every 5s of idle, and surface a genuinely dead peer in ~35s.
if [ -n "$BENCH_DSN" ] && [[ "$BENCH_DSN" != *keepalives=* ]]; then
  if [[ "$BENCH_DSN" == *\?* ]]; then BENCH_DSN="$BENCH_DSN&"; else BENCH_DSN="$BENCH_DSN?"; fi
  BENCH_DSN="${BENCH_DSN}keepalives=1&keepalives_idle=5&keepalives_interval=5&keepalives_count=6"
fi

mkdir -p "$RESULTS"

# Always reap background load drivers, even on error/interrupt -- an orphaned
# pgbench keeps holding locks and corrupts the next run.
BG_PIDS=()
cleanup() { local p; for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

# ---- psql helpers (DSN passed positionally, never logged) ------------------
# Managed Postgres (e.g. Supabase) injects a per-connection statement_timeout
# (2min) that ALTER DATABASE/ROLE can't override and the pooler drops startup
# `options`, so disable it (+ lock_timeout) in-session on every connection. The
# long statements here -- bulk generate, adopt's index build, the drain's
# VALIDATE CONSTRAINT scan, the final VACUUM -- all exceed a 2min cap. The SETs
# go in their OWN -c so the actual command runs in its own implicit transaction:
# folding them into one -c string would wrap everything in a single transaction,
# and bench.generate_events() is a procedure that COMMITs (illegal in a txn block).
# SET tags are suppressed by -q, so captured query output stays clean.
TO_OFF="set statement_timeout=0; set lock_timeout=0"
conn_args() { if [ -n "$BENCH_DSN" ]; then printf '%s' "$BENCH_DSN"; fi; }
q()  { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; fi; }
qf() { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -c "$TO_OFF" -f "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -c "$TO_OFF" -f "$1"; fi; }
say() { printf '\n\033[1;36m== %s ==\033[0m %s\n' "$1" "$(q "select to_char(now(),'HH24:MI:SS')")"; }

have_ext() { [ "$(q "select count(*) from pg_extension where extname='$1'")" = "1" ]; }
have_pgss=0
have_pgfr=0
# psql -f with single-transaction (pgfr installs want all-or-nothing)
qf1() { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -c "$TO_OFF" --single-transaction -f "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -c "$TO_OFF" --single-transaction -f "$1"; fi; }

pgss_reset() { [ "$have_pgss" = "1" ] && q "select pg_stat_statements_reset()" >/dev/null || true; }
# snapshot the workload statements (server-side, WAN-free timing) for a phase
pgss_snapshot() {
  [ "$have_pgss" = "1" ] || return 0
  local label="$1"
  q "copy (
       select '$label' as phase, calls,
              round(total_exec_time::numeric,1) as total_ms,
              round(mean_exec_time::numeric,4)  as mean_ms,
              round(stddev_exec_time::numeric,4) as stddev_ms,
              rows, left(regexp_replace(query,'\s+',' ','g'),80) as query
       from pg_stat_statements
       where query ilike '%bench.%' and query not ilike '%pg_stat_statements%'
       order by total_exec_time desc limit 15
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.pgss.csv"
}

# top temp-file writers across ALL statements this phase -- attributes pgfr's TEMP_FILE_SPILLS
# to a concrete query (workload? index build? pgfr's own collection?) instead of guessing.
temp_snapshot() {
  [ "$have_pgss" = "1" ] || return 0
  local label="$1"
  q "copy (
       select '$label' as phase, calls,
              round(temp_blks_written*8/1024.0,1) as temp_mb_written,
              round(total_exec_time::numeric,1) as total_ms,
              left(regexp_replace(query,'\s+',' ','g'),110) as query
       from pg_stat_statements
       where temp_blks_written > 0
       order by temp_blks_written desc limit 15
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.temp.csv"
}

# total size of bench.events INCLUDING all partitions (a partitioned parent has no
# heap of its own, so pg_total_relation_size(parent) alone reads 0 post-conversion)
EVENTS_SIZE_SUB="(select pg_size_pretty(coalesce((select sum(pg_total_relation_size(c.oid)) from pg_class c
        where c.oid='bench.events'::regclass
           or c.oid in (select inhrelid from pg_inherits where inhparent='bench.events'::regclass)),0)))"

# NOTE: the system-wide gauges that used to live here (per-phase WAL/checkpoint/health/IO
# snapshots + a hand-rolled WAL delta table) were removed. pg_flight_recorder already records
# all of that continuously and server-side -- WAL bytes/time, checkpoints, pg_stat_io,
# wait/lock events, table sizes -- so the report slices pgfr's time-series by the phase
# boundaries instead of re-deriving a coarse subset by hand. The harness keeps only what pgfr
# can't: client-side pgbench latency (pctiles), per-phase workload statement latency (pgss),
# and pgpm's own conversion progress (the convert loop).

# percentiles (µs -> ms) from pgbench --log files for a label. Optional epoch window [lo,hi]
# (args 2,3) restricts to transactions logged in that range -- used by window mode to measure
# only the steady-state slice (col 5 is the epoch second); 0/absent means "all transactions".
pctiles() {
  local label="$1" lo="${2:-0}" hi="${3:-0}" files
  # pgbench --log-prefix=X writes "X.<pid>" and "X.<pid>.<thread>" (no .log suffix)
  files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a"; return 0; }
  # shellcheck disable=SC2086
  awk -v lo="$lo" -v hi="$hi" 'lo==0 || ($5+0 >= lo && $5+0 <= hi) {print $3}' $files | sort -n | awk '
    function pct(p,   i){ i=int(p*n); if(i>=n)i=n-1; return a[i]/1000.0 }
    { a[n++]=$1 }
    END {
      if (n==0) { print "n/a"; exit }
      printf "n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", n, pct(0.50), pct(0.95), pct(0.99), a[n-1]/1000.0
    }'
}

# tps + avg-latency for a label DERIVED from the pgbench --log (the convert pgbench is killed
# and prints no summary). Optional epoch window [lo,hi] (args 2,3) restricts to that slice, so
# window mode measures only steady-state draining. Emits "tps = ...|latency average = ... ms".
pgbench_log_summary() {
  local label="$1" lo="${2:-0}" hi="${3:-0}" files
  files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a|n/a"; return 0; }
  # col3 = per-txn latency (us); cols 5,6 = epoch seconds + us-within-second. Require a real
  # epoch in $5 so a truncated final line can't poison the elapsed span (-> tps ~0); the same
  # guard naturally drops out-of-window rows. tps is over the window's own min..max span.
  # shellcheck disable=SC2086
  awk -v lo="$lo" -v hi="$hi" '$5+0 > 1000000000 && (lo==0 || ($5+0 >= lo && $5+0 <= hi)) {
         n++; lat+=$3; t=$5+$6/1e6; if(mn==0||t<mn)mn=t; if(t>mx)mx=t }
       END{ if(n==0){print "n/a|n/a"; exit}
            el=mx-mn; if(el<=0)el=1;
            printf "tps = %.1f (from --log)|latency average = %.1f ms", n/el, (lat/n)/1000.0 }' $files
}

# run a fixed-duration load phase; capture pgbench summary + client percentiles + the
# workload's per-phase server-side statement latency (pgss). System metrics are pgfr's job.
run_phase() {
  local label="$1" secs="$2"
  say "load phase: $label (${secs}s, ${BENCH_CLIENTS} clients)"
  pgss_reset
  local args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$secs" -P 5
               -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench"
               --log "--log-prefix=$RESULTS/pgb_$label" )
  rm -f "$RESULTS/pgb_$label".*
  if [ -n "$BENCH_DSN" ]; then "$PGBENCH" "$BENCH_DSN" "${args[@]}"; else "$PGBENCH" "${args[@]}"; fi \
    | tee "$RESULTS/$label.pgbench.txt"
  pgss_snapshot "$label"; temp_snapshot "$label"
  printf '%s\n' "$(pctiles "$label")" > "$RESULTS/$label.pctiles.txt"
  echo "  latency: $(cat "$RESULTS/$label.pctiles.txt")"
}

# Fail fast: a workload that's timing out (BENCH_OPS too high for the data's
# disk-bound per-op cost at scale) shows up as high failure % / collapsed tps in
# the FIRST phase. Abort now instead of limping for hours through a useless run.
assert_workload_healthy() {
  local label="$1" f tps
  f=$(grep -oE 'number of failed transactions: [0-9]+ \([0-9.]+%\)' "$RESULTS/$label.pgbench.txt" 2>/dev/null \
        | grep -oE '[0-9.]+%' | head -1 | tr -d '%')
  tps=$(grep -oE 'tps = [0-9.]+' "$RESULTS/$label.pgbench.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+')
  f=${f:-100}; tps=${tps:-0}
  if awk -v f="$f" -v m="$BENCH_MAX_FAIL_PCT" 'BEGIN{exit !(f+0 > m+0)}'; then
    echo "  ABORT: ${f}% of '$label' transactions FAILED (> ${BENCH_MAX_FAIL_PCT}%)."
    echo "         The workload is mis-calibrated for this scale -- almost always BENCH_OPS too high,"
    echo "         so each transaction exceeds statement_timeout. Lower BENCH_OPS and re-run."
    exit 2
  fi
  if awk -v t="$tps" 'BEGIN{exit !(t+0 < 1)}'; then
    echo "  ABORT: '$label' tps=$tps -- workload not making progress (check BENCH_OPS / connectivity)."
    exit 2
  fi
  echo "  workload health OK ($label: ${f}% failed, ${tps} tps)"
}

# ---- 0. preflight ----------------------------------------------------------
say "preflight"
q "select version()" | sed 's/^/  /'
if ! have_ext pg_cron; then
  echo "  NOTE: pg_cron not installed; pgpm install needs it. Attempting create extension..."
  q "create extension if not exists pg_cron" || { echo "  ERROR: pg_cron required"; exit 1; }
fi
# pg_stat_statements is only usable if it's in shared_preload_libraries; CREATE
# EXTENSION can succeed yet the functions still error, so verify with a reset.
if q "create extension if not exists pg_stat_statements" >/dev/null 2>&1 \
   && q "select pg_stat_statements_reset()" >/dev/null 2>&1; then
  have_pgss=1; echo "  pg_stat_statements: on (server-side latency capture enabled)"
else
  echo "  pg_stat_statements: unavailable (not preloaded; relying on pgbench --log timing)"
fi

# ---- 1. install pgpm (+ optional pg_flight_recorder) -----------------------
say "install pg_partition_magician"
qf "$REPO_ROOT/sql/pg_partition_magician.sql" >/dev/null
echo "  pgpm installed: $(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgpm'") functions"
if [ "$BENCH_PGFR" = "1" ]; then
  if [ -f "$BENCH_PGFR_DIR/pgfr_record/install.sql" ]; then
    say "install pg_flight_recorder (record + analyze) and enable collection"
    # non-fatal: a pgfr hiccup (e.g. pg_stat_statements not preloaded) must not kill the run
    if qf1 "$BENCH_PGFR_DIR/pgfr_record/install.sql" >/dev/null 2>&1 \
       && q "select pgfr_record.enable()" >/dev/null 2>&1; then
      qf1 "$BENCH_PGFR_DIR/pgfr_analyze/install.sql" >/dev/null 2>&1 \
        || echo "  note: pgfr_analyze install skipped (reports unavailable; record alone covers capture)"
      q "select pgfr_record.apply_profile('troubleshooting')" >/dev/null 2>&1 || true
      have_pgfr=1
      echo "  pg_flight_recorder: enabled ($(q "select count(*) from cron.job where jobname like 'pgfr%'" 2>/dev/null || echo '?') cron jobs)"
    else
      echo "  pg_flight_recorder: install/enable failed (needs pg_stat_statements preloaded), continuing without pgfr"
    fi
  else
    echo "  WARNING: BENCH_PGFR=1 but $BENCH_PGFR_DIR/pgfr_record/install.sql not found; skipping pgfr"
  fi
fi

# ---- 2. schema + data (server-side generation) -----------------------------
if [ "$BENCH_SKIP_GENERATE" = "1" ]; then
  say "skip generate (BENCH_SKIP_GENERATE=1)"
else
  say "build schema + generate data SERVER-SIDE"
  qf "$BENCH_DIR/sql/00_schema.sql" >/dev/null
  qf "$BENCH_DIR/sql/10_generate.sql" >/dev/null
  if [ "$BENCH_DEFER_INDEX" = "1" ]; then
    echo "  deferring secondary index during bulk load (rebuilt after)"
    q "drop index if exists bench.events_user_created_idx" >/dev/null
  fi
  if [ "$BENCH_GEN_JOBS" -le 1 ]; then
    echo "  generating $BENCH_ROWS rows across $BENCH_MONTHS months (1 session, in-database, nothing on the wire)..."
    q "call bench.generate_events($BENCH_ROWS, $BENCH_MONTHS, $BENCH_CHUNK)"
  else
    # one INSERT..SELECT is single-core-bound; split the target across N sessions
    # that all append to bench.events concurrently (the identity sequence keeps ids
    # unique). They each spread rows over the same month span, so the distribution
    # is unchanged.
    echo "  generating $BENCH_ROWS rows across $BENCH_MONTHS months via $BENCH_GEN_JOBS parallel sessions..."
    gen_base=$(( BENCH_ROWS / BENCH_GEN_JOBS ))
    gen_rem=$(( BENCH_ROWS - gen_base * BENCH_GEN_JOBS ))
    gen_pids=()
    for j in $(seq 1 "$BENCH_GEN_JOBS"); do
      rows_j=$gen_base
      [ "$j" -eq 1 ] && rows_j=$(( gen_base + gen_rem ))   # job 1 absorbs the remainder
      ( q "call bench.generate_events($rows_j, $BENCH_MONTHS, $BENCH_CHUNK)" \
          > "$RESULTS/generate_job_$j.log" 2>&1 ) &
      pid=$!; gen_pids+=("$pid"); BG_PIDS+=("$pid")
      echo "    job $j: $rows_j rows (pid $pid)"
    done
    gen_fail=0
    for pid in "${gen_pids[@]}"; do wait "$pid" || gen_fail=1; done
    [ "$gen_fail" = "0" ] || { echo "  ERROR: a generator session failed; see $RESULTS/generate_job_*.log"; exit 1; }
  fi
  if [ "$BENCH_DEFER_INDEX" = "1" ]; then
    echo "  rebuilding secondary index on the full table (sort build, no statement_timeout)..."
    q "create index if not exists events_user_created_idx on bench.events (user_id, created_at desc)" >/dev/null
  fi
  if [ "$BENCH_PREFREEZE" = "1" ]; then
    # Settle the post-bulk-load freeze/hint-bit WAL NOW, synchronously, before baseline. A fresh
    # bulk load leaves tens of millions of unfrozen tuples; the first autovacuum rewrites every
    # page (FPIs -> WAL), which at scale fires forced checkpoints and temp during the convert
    # WINDOW and reads as drain I/O. Freezing here pushes that aftermath outside the window so the
    # windowed pgfr metrics reflect the gentle drain, not the load. (ANALYZE folded in.)
    echo "  pre-freeze: VACUUM (FREEZE, ANALYZE) bench.events -- settle load aftermath out of the window..."
    q "vacuum (freeze, analyze) bench.events" >/dev/null
  else
    q "analyze bench.events" >/dev/null   # fresh stats after load (+ any index rebuild)
  fi
fi
qf "$BENCH_DIR/sql/20_workload.sql" >/dev/null
echo "  events: $(q "select count(*) from bench.events") rows, $(q "select pg_size_pretty(pg_total_relation_size('bench.events'))")"

# ---- 3. baseline (unpartitioned, under load) -------------------------------
run_phase baseline "$BENCH_PHASE_SECS"
assert_workload_healthy baseline   # bail now if the workload is timing out, before adopt/drain/post

# ---- 4. conversion: trigger pgpm ONCE, then OBSERVE it self-drive -----------
# The benchmark does NOT perform the partitioning. It sets pgpm up the way an operator
# does -- fire adopt() once (unpaused) and schedule pgpm.maintenance on pg_cron -- and then
# pgpm's OWN cron jobs premake + drain the default autonomously, inside the database. The
# harness only runs the ambient workload and OBSERVES (samples + watches pgpm.log) until the
# drain settles. Nothing here calls drain_step or premake; a dropped observer connection
# can't stop the conversion, because the conversion isn't running on this connection.
say "conversion: trigger pgpm.adopt, then observe pgpm self-drive (pg_cron) under load"
pgss_reset
rm -f "$RESULTS/pgb_convert".*
# one continuous ambient workload spanning the whole conversion (prep + adopt + drain).
# Background pgbench DIRECTLY (not inside a `( ... ) &` subshell): $! must be the pgbench pid
# itself, or cleanup() kills only the subshell wrapper and pgbench is reparented and orphaned --
# left hammering the server (holding connections/locks) and corrupting the next run.
conv_bg_secs=$(( BENCH_DRAIN_MAX_SECS + 1200 ))
conv_args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$conv_bg_secs" -P 5
            -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" --log "--log-prefix=$RESULTS/pgb_convert" )
if [ -n "$BENCH_DSN" ]; then
  "$PGBENCH" "$BENCH_DSN" "${conv_args[@]}" > "$RESULTS/convert.pgbench.txt" 2>&1 &
else
  "$PGBENCH" "${conv_args[@]}" > "$RESULTS/convert.pgbench.txt" 2>&1 &
fi
load_pid=$!; BG_PIDS+=("$load_pid")
convert_start=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")   # conversion window start (for slicing pgfr)

# 4. the single operator trigger: adopt() unpaused. pgpm takes it from here. No PK pre-build is
# needed any more -- pgpm never rewrites the PK (the partition key leads the PK, so it is reused in
# place), so the cutover is always metadata-only. See DESIGN.md section 8.
echo "  firing pgpm.adopt('bench.events','created_at', interval '$BENCH_INTERVAL', paused=>false)..."
adopt_t0=$(q "select extract(epoch from clock_timestamp())")
q "select pgpm.adopt('bench.events','created_at', interval '$BENCH_INTERVAL', $BENCH_PREMAKE, p_paused => false, p_drain_batch => $BENCH_DRAIN_BATCH)" >/dev/null
adopt_t1=$(q "select extract(epoch from clock_timestamp())")
awk -v a="$adopt_t0" -v b="$adopt_t1" 'BEGIN{printf "  adopt() returned in %.1fs (metadata cutover)\n", b-a}'

# 4b. adaptive feathering (DESIGN.md sec 8, mode 2): let the drain ride its budget against checkpoint
#     pressure (AIMD) instead of the fixed drain_batch. BENCH_DRAIN_ADAPTIVE=0 keeps mode 1 (fixed).
if [ "${BENCH_DRAIN_ADAPTIVE:-1}" = "1" ]; then
  q "select pgpm.set_drain_adaptive('bench.events', true)" >/dev/null
  echo "  adaptive feathering ENABLED (drain budget self-tunes around drain_batch=$BENCH_DRAIN_BATCH)"
  # Optionally arm the SELF-CALIBRATING ambient signal: learn the recent waiter baseline (EWMA) and
  # back off on a relative surge above it. BENCH_DRAIN_AMBIENT_FACTOR>0 turns it on (e.g. 2.0 = back off
  # when live waiters exceed 2x the learned normal). This is the box-independent successor to the fixed
  # threshold and is what isolates a write surge from steady-state contention.
  if [ -n "${BENCH_DRAIN_AMBIENT_FACTOR:-}" ] && awk -v f="$BENCH_DRAIN_AMBIENT_FACTOR" 'BEGIN{exit !(f>0)}'; then
    q "select pgpm.set_drain_ambient('bench.events', ${BENCH_DRAIN_AMBIENT_FACTOR}, ${BENCH_DRAIN_AMBIENT_ALPHA:-0.2}, ${BENCH_DRAIN_AMBIENT_FLOOR:-2})" >/dev/null
    echo "  self-calibrating ambient signal ENABLED (back off when waiters > ${BENCH_DRAIN_AMBIENT_FACTOR}x the learned baseline, floor ${BENCH_DRAIN_AMBIENT_FLOOR:-2})"
  fi
  # Optionally arm the legacy absolute cap too: back off when > N non-pgpm backends are IO/lock-stuck.
  if [ "${BENCH_DRAIN_AMBIENT_WAITERS:-0}" -gt 0 ]; then
    q "update pgpm.config set drain_ambient_max_waiters = $BENCH_DRAIN_AMBIENT_WAITERS where parent_table='bench.events'::regclass" >/dev/null
    echo "  ambient absolute cap ENABLED (yield when > $BENCH_DRAIN_AMBIENT_WAITERS workload backends are IO/lock-stuck)"
  fi
else
  echo "  adaptive feathering off (mode 1: fixed drain_batch=$BENCH_DRAIN_BATCH)"
fi

# 4c. schedule pgpm.maintenance on pg_cron -- THIS is how pgpm self-drives premake + drain
#     (standard pgpm operation; the operator schedules it once; pg_cron skips overlapping runs)
q "select cron.unschedule(jobid) from cron.job where jobname='pgpm_maint_bench'" >/dev/null 2>&1 || true
q "select cron.schedule('pgpm_maint_bench', '$BENCH_MAINT_INTERVAL', 'call pgpm.maintenance_all()')" >/dev/null
echo "  scheduled pgpm.maintenance on pg_cron every '$BENCH_MAINT_INTERVAL' -- pgpm is now draining itself"

# 4d. OBSERVE. settle mode -> watch pgpm.log until the drain STARTS (>=1 op) and then goes quiet
#     for BENCH_DRAIN_IDLE_SECS (closed tail fully drained). window mode -> warm up until the
#     drain is steadily running (>=1 op and BENCH_CONVERT_WARMUP_SECS elapsed), then measure for
#     BENCH_CONVERT_WINDOW_SECS without waiting for completion; convert metrics are restricted to
#     [conv_win_lo,conv_win_hi] so the one-time adopt cutover is excluded. A failed poll is
#     non-fatal (transient WAN blip) -- retry; the drain runs server-side regardless. The stall
#     detector (drain never starts) and the BENCH_DRAIN_MAX_SECS cap apply in both modes.
: > "$RESULTS/drain.progress.csv"
echo "observed_s,default_rows,partitions,drain_ops,last_drain_age_s,drain_budget,ambient_waiters,ambient_baseline,surge_active" >> "$RESULTS/drain.progress.csv"
obs_start=$(q "select extract(epoch from clock_timestamp())")
drain_started=0; warned_stall=0; window_start=0; conv_win_lo=0; conv_win_hi=0
warned_stall_settle=0; last_closed_check=0
surge_pid=""; surge_launched=0; surge_active=0
while :; do
  sleep "$BENCH_OBSERVE_INTERVAL"
  # ONE round-trip per poll (fewer fresh connections over the NAT'd path = less churn/risk):
  #   epoch | default n_live_tup | partition count | drain ops | secs since last drain op (-1) | drain_budget (-1 if not adaptive)
  poll=$(q "select extract(epoch from clock_timestamp())::bigint
            ||'|'|| coalesce((select n_live_tup from pg_stat_user_tables where relid='bench.events_default'::regclass),-1)
            ||'|'|| (select count(*) from pg_inherits where inhparent='bench.events'::regclass)
            ||'|'|| (select count(*) from pgpm.log where parent_table='bench.events'::regclass and action in ('drain_move','drain_attach'))
            ||'|'|| coalesce((select round(extract(epoch from (clock_timestamp()-max(at))))::int
                              from pgpm.log where parent_table='bench.events'::regclass and action in ('drain_move','drain_attach')),-1)
            ||'|'|| coalesce((select rows from pgpm.log where parent_table='bench.events'::regclass and action='drain_budget' order by at desc limit 1),-1)
            ||'|'|| coalesce(pgpm._ambient_io_waiters(),-1)
            ||'|'|| coalesce((select round(drain_ambient_baseline,2) from pgpm.config where parent_table='bench.events'::regclass),-1)" 2>/dev/null) \
    || { echo "  (observe poll failed -- retrying)"; continue; }
  IFS='|' read -r now_s drows nparts moves age budget waiters baseline <<<"$poll"
  elapsed=$(awk -v a="$obs_start" -v b="$now_s" 'BEGIN{printf "%.0f", b-a}')

  # ambient write-surge: launch a write-heavy pgbench burst BENCH_SURGE_AFTER_SECS into the observe
  # phase, stop it BENCH_SURGE_SECS later. The drain_budget column should dip while surge_active=1.
  if [ "${BENCH_SURGE_CLIENTS:-0}" -gt 0 ]; then
    if [ "$surge_launched" = 0 ] && [ "$elapsed" -ge "$BENCH_SURGE_AFTER_SECS" ]; then
      say "AMBIENT SURGE: launching $BENCH_SURGE_CLIENTS write-heavy clients for ${BENCH_SURGE_SECS}s (rows/call=$BENCH_SURGE_ROWS)"
      surge_args=( -n -c "$BENCH_SURGE_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_SURGE_SECS"
                   -D "rows=$BENCH_SURGE_ROWS" -f "$BENCH_DIR/surge.pgbench" )
      if [ -n "$BENCH_DSN" ]; then
        "$PGBENCH" "$BENCH_DSN" "${surge_args[@]}" >"$RESULTS/surge.pgbench.txt" 2>&1 &
      else
        "$PGBENCH" "${surge_args[@]}" >"$RESULTS/surge.pgbench.txt" 2>&1 &
      fi
      surge_pid=$!; BG_PIDS+=("$surge_pid"); surge_launched=1; surge_active=1
    elif [ "$surge_active" = 1 ] && { [ -z "$surge_pid" ] || ! kill -0 "$surge_pid" 2>/dev/null; }; then
      surge_active=0; echo; echo "  ambient surge ended"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$elapsed" "$drows" "$nparts" "$moves" "$age" "$budget" "$waiters" "$baseline" "$surge_active" >> "$RESULTS/drain.progress.csv"
  if [ "$moves" -ge 1 ]; then drain_started=1; fi

  if [ "$BENCH_OBSERVE_MODE" = window ]; then
    if [ "$window_start" = 0 ] && [ "$drain_started" = 1 ] && [ "$elapsed" -ge "$BENCH_CONVERT_WARMUP_SECS" ]; then
      window_start="$now_s"; conv_win_lo="$now_s"
      echo; echo "  warmed up ($moves drain ops in ${elapsed}s) -- measuring a ${BENCH_CONVERT_WINDOW_SECS}s steady-state window"
    fi
    if [ "$window_start" != 0 ]; then
      win_el=$(awk -v a="$window_start" -v b="$now_s" 'BEGIN{printf "%.0f", b-a}')
      printf '\r  measuring: window %ss/%ss, default~%s rows, %s drain ops   ' "$win_el" "$BENCH_CONVERT_WINDOW_SECS" "$drows" "$moves"
      if [ "$win_el" -ge "$BENCH_CONVERT_WINDOW_SECS" ]; then
        conv_win_hi="$now_s"
        echo; echo "  measurement window complete (${win_el}s steady-state; $moves drain ops; drain left running server-side)"; break
      fi
    else
      printf '\r  warming up: %ss, default~%s rows, %s drain ops   ' "$elapsed" "$drows" "$moves"
    fi
  else
    printf '\r  observing: %ss, default~%s rows, %s partitions, %s drain ops, last drain %ss ago   ' "$elapsed" "$drows" "$nparts" "$moves" "$age"
    if [ "$drain_started" = 1 ] && [ "$age" != '-1' ] && [ "$age" -ge "$BENCH_DRAIN_IDLE_SECS" ]; then
      # Idle for IDLE_SECS. In run-to-completion (settle) mode, "settled" must mean the closed tail is
      # actually EMPTY -- not merely that the drain log went quiet. An I/O stall (a forced-checkpoint
      # storm on a burst-limited disk) also looks idle, and breaking on it falsely reports completion
      # with millions of rows still in the DEFAULT. Distinguish the two with a closed-rows check, run at
      # most once per idle window (the count scan is not free at scale): closed==0 => truly done;
      # closed>0 => a stall, so keep observing until the drain resumes or we hit the cap.
      if [ "$last_closed_check" = 0 ] || awk -v n="$now_s" -v l="$last_closed_check" -v w="$BENCH_DRAIN_IDLE_SECS" 'BEGIN{exit !(n-l >= w)}'; then
        last_closed_check="$now_s"
        closed=$(q "select coalesce((select closed_rows from pgpm.check_default('bench.events')),-1)" 2>/dev/null || echo -1)
        if [ "$closed" = 0 ]; then
          echo; echo "  pgpm drain settled -- $moves drain ops, closed tail empty (0 rows below the frontier)"; break
        elif [ "$warned_stall_settle" = 0 ]; then
          warned_stall_settle=1
          echo; echo "  NOTE: drain idle ${age}s but ${closed} closed rows remain -- I/O stall, not completion; observing to the cap"
        fi
      fi
    fi
  fi

  # Stall detector (both modes): maintenance was scheduled but no drain op has landed.
  if [ "$drain_started" = 0 ] && [ "$warned_stall" = 0 ] && [ "$elapsed" -ge 60 ]; then
    warned_stall=1
    echo; echo "  WARNING: no drain activity after ${elapsed}s -- pgpm.maintenance may be failing. Recent cron runs:"
    q "select start_time::time(0)||' '||status||' '||left(coalesce(return_message,''),80)
         from cron.job_run_details where jobid in (select jobid from cron.job where jobname='pgpm_maint_bench')
         order by start_time desc limit 3" 2>/dev/null | sed 's/^/    /' || true
  fi
  # Cap backstop (both modes).
  if awk -v e="$elapsed" -v m="$BENCH_DRAIN_MAX_SECS" 'BEGIN{exit !(e+0 > m+0)}'; then
    echo; echo "  observation hit cap ${BENCH_DRAIN_MAX_SECS}s; stopping (mode=$BENCH_OBSERVE_MODE, drain_started=$drain_started, $moves ops)"
    if [ "$BENCH_OBSERVE_MODE" = window ] && [ "$window_start" != 0 ]; then conv_win_hi="$now_s"; fi
    break
  fi
done
kill "$load_pid" 2>/dev/null || true; wait "$load_pid" 2>/dev/null || true
q "select cron.unschedule(jobid) from cron.job where jobname='pgpm_maint_bench'" >/dev/null 2>&1 || true
convert_end=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")   # conversion window end (for slicing pgfr)
# if window mode never closed a window (drain never warmed up), fall back to whole-convert metrics
if [ "$BENCH_OBSERVE_MODE" = window ] && [ "$conv_win_hi" = 0 ]; then conv_win_lo=0; fi
pgss_snapshot convert; temp_snapshot convert
printf '%s\n' "$(pctiles convert "$conv_win_lo" "$conv_win_hi")" > "$RESULTS/convert.pctiles.txt"
echo "  ambient-workload latency through the conversion: $(cat "$RESULTS/convert.pctiles.txt")"

# ---- 5. post (partitioned, under load) -------------------------------------
# Pure observer: no operator VACUUM here. pgpm tuned autovacuum aggressively on the
# default at adopt, so post observes the real post-conversion steady state as it settles.
run_phase post "$BENCH_PHASE_SECS"

# ---- 7. report -------------------------------------------------------------
say "report"
{
  echo "# pg_partition_magician: at-scale load test"
  echo
  echo "- rows: $(q "select count(*) from bench.events")"
  echo "- events size: $(q "select $EVENTS_SIZE_SUB")"
  echo "- partitions: $(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")"
  echo "- clients: $BENCH_CLIENTS, ops/call: $BENCH_OPS, drain batch: $BENCH_DRAIN_BATCH (pgpm-driven via pg_cron every '$BENCH_MAINT_INTERVAL')"
  echo
  echo "## throughput / latency by phase (client-side, pgbench)"
  echo
  echo "| phase | pgbench tps | pgbench avg latency | client p50 / p95 / p99 (pgbench --log) |"
  echo "|-------|-------------|---------------------|----------------------------------------|"
  for ph in baseline convert post; do
    if [ "$ph" = convert ] && [ "$BENCH_OBSERVE_MODE" = window ]; then
      # window mode: the convert pgbench's own summary (if it printed one when killed) spans the
      # WHOLE convert incl. warmup/cutover and isn't windowed -- always derive convert tps/avg
      # from the windowed log slice instead, consistent with the windowed pctiles.
      s=$(pgbench_log_summary convert "$conv_win_lo" "$conv_win_hi"); tps=${s%%|*}; lat=${s##*|}
    else
      tps=$(grep -h 'tps =' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || true)
      lat=$(grep -h 'latency average' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || true)
      # convert (settle mode) is killed and prints no summary -> derive tps/avg from its log
      if [ -z "$tps" ]; then s=$(pgbench_log_summary "$ph"); tps=${s%%|*}; lat=${s##*|}; fi
    fi
    pct=$(cat "$RESULTS/$ph.pctiles.txt" 2>/dev/null || echo "n/a")
    printf '| %s | %s | %s | %s |\n' "$ph" "${tps:-n/a}" "${lat:-n/a}" "$pct"
  done
  echo
  echo "## conversion (pgpm self-driven, from pgpm.log)"
  echo
  if [ "$BENCH_OBSERVE_MODE" = window ]; then
    echo "- mode: **gentle / steady-state window** -- measured ~${BENCH_CONVERT_WINDOW_SECS}s of draining"
    echo "  after a ${BENCH_CONVERT_WARMUP_SECS}s warm-up; the drain was deliberately NOT run to completion."
    echo "  **Verdict = the latency comparison** (convert p50/p95/p99 vs baseline): if they track, the drain"
    echo "  is unnoticeable. Throughput (tps) over the window is NOT the verdict -- for a fixed client count"
    echo "  tps is ~clients/latency, so it only drops if latency rises OR if the workload driver loses its"
    echo "  connection mid-window (a client/network stall reads as a tps drop with UNCHANGED latency). See"
    echo "  \`convert.pgbench.txt\` progress lines for per-interval steady-state tps."
  else
    echo "- mode: **stress / run-to-completion** -- drove the drain until the closed tail fully drained."
  fi
  echo "- conversion window: \`$convert_start\` -> \`$convert_end\`"
  echo "- drain: $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='drain_move'") moves, $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='drain_attach'") partition attaches, $(q "select coalesce(sum(rows),0) from pgpm.log where parent_table='bench.events'::regclass and action='drain_move'") rows moved"
  echo "- premake: $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='premake'") succeeded, $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='premake_skip'") deferred under lock contention"
  if [ "${BENCH_DRAIN_ADAPTIVE:-1}" = "1" ]; then
    echo "- adaptive feathering (mode 2): $(q "select coalesce(min(rows),0)||'-'||coalesce(max(rows),0) from pgpm.log where parent_table='bench.events'::regclass and action='drain_budget'") rows/tick budget range over $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='drain_budget'") steps, $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='drain_budget' and method<>'probe'") backoffs ($(q "select coalesce(string_agg(method||':'||c,', '),'none') from (select method, count(*) c from pgpm.log where parent_table='bench.events'::regclass and action='drain_budget' and method<>'probe' group by method order by 2 desc) s") )"
  fi
  if [ "$BENCH_OBSERVE_MODE" = window ]; then
    echo "- default closed-tail rows remaining: $(q "select coalesce((select closed_rows from pgpm.check_default('bench.events')),-1)") (still draining -- not expected to be 0 in a windowed run)"
  else
    echo "- default closed-tail rows remaining: $(q "select coalesce((select closed_rows from pgpm.check_default('bench.events')),-1)") (0 = closed tail fully converted)"
  fi
  echo "- drain rate trace: \`drain.progress.csv\` (observed_s, default_rows, partitions, drain_ops, drain_budget, ambient_waiters, ambient_baseline, surge_active)"
  echo
  if [ "$have_pgfr" = "1" ]; then
    echo "## system metrics (pg_flight_recorder)"
    echo
    echo "WAL, checkpoints, \`pg_stat_io\`, and wait/lock events were recorded continuously and"
    echo "server-side by pgfr. Slice its time-series to the conversion window above"
    echo "(\`$convert_start\` -> \`$convert_end\`). Full-run narrative: \`pgfr_report.md\`."
  else
    echo "## system metrics"
    echo
    echo "_(pg_flight_recorder not enabled -- set BENCH_PGFR=1 for the WAL / checkpoint / pg_stat_io /"
    echo "wait-event time-series. The harness no longer hand-rolls these; pgfr is the recorder.)_"
  fi
  echo
  echo "Per-phase server-side workload statement latency: \`*.pgss.csv\`."
  echo "Per-phase temp-file (work_mem-spill) attribution: \`*.temp.csv\`."
} > "$RESULTS/report.md"

# pg_flight_recorder narrative, focused on the conversion window (analyze) + stop collection
if [ "$have_pgfr" = "1" ]; then
  # the narrative report() (anomalies / wait-event summary / snapshot deltas), scoped to the
  # conversion window -- NOT incident_timeline(), which is a raw per-event firehose.
  q "select pgfr_analyze.report('$convert_start'::timestamptz,'$convert_end'::timestamptz)" > "$RESULTS/pgfr_report.md" 2>/dev/null \
    || q "select pgfr_analyze.report('1 hour')" > "$RESULTS/pgfr_report.md" 2>/dev/null \
    || q "select pgfr_analyze.incident_timeline('$convert_start','$convert_end')" > "$RESULTS/pgfr_report.md" 2>/dev/null \
    || echo "(pgfr_analyze report unavailable)" > "$RESULTS/pgfr_report.md"
  q "select pgfr_record.disable()" >/dev/null 2>&1 || true
fi

cat "$RESULTS/report.md"
echo
echo "Full artifacts in $RESULTS/"
