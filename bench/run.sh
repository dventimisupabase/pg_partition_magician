#!/usr/bin/env bash
# At-scale load test for pg_partition_magician.
#
# Builds a multi-table DB with one giant time-series table (bench.events),
# generates the bulk DATA SERVER-SIDE (nothing crosses the wire), then drives a
# steady index-supported OLTP workload while pg_partition_magician converts the
# giant table to partitioned ONLINE. Captures latency/throughput/health before,
# during, and after the conversion so the impact is measurable.
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
BENCH_INTERVAL="${BENCH_INTERVAL:-1 month}" # partition width
BENCH_PREMAKE="${BENCH_PREMAKE:-3}"

BENCH_CLIENTS="${BENCH_CLIENTS:-16}"        # pgbench concurrent clients
BENCH_JOBS="${BENCH_JOBS:-4}"               # pgbench worker threads
BENCH_OPS="${BENCH_OPS:-50}"                # server-side ops per workload_step call
BENCH_PHASE_SECS="${BENCH_PHASE_SECS:-120}" # per-phase load duration (baseline/post)
BENCH_ADOPT_WARM="${BENCH_ADOPT_WARM:-15}"  # load lead-in before firing adopt
BENCH_MAX_FAIL_PCT="${BENCH_MAX_FAIL_PCT:-5}"  # abort if baseline workload exceeds this failure % (mis-calibrated BENCH_OPS)

BENCH_DRAIN_BATCH="${BENCH_DRAIN_BATCH:-20000}"  # rows per drain_step
BENCH_DRAIN_SLEEP="${BENCH_DRAIN_SLEEP:-0}"      # pause between drain steps (s); 0 = full speed
BENCH_DRAIN_MAX_SECS="${BENCH_DRAIN_MAX_SECS:-3600}"  # safety cap on the drain window

BENCH_PGFR="${BENCH_PGFR:-0}"               # 1 = wire in pg_flight_recorder (best-effort; needs elevated privs, PG15-17)
BENCH_PGFR_DIR="${BENCH_PGFR_DIR:-$BENCH_DIR/vendor/pg_flight_recorder}"  # pgfr checkout (pgfr_record + pgfr_analyze)
BENCH_SKIP_GENERATE="${BENCH_SKIP_GENERATE:-0}"  # 1 = data already loaded, skip 00/10
BENCH_DEFER_INDEX="${BENCH_DEFER_INDEX:-0}"      # 1 = drop the secondary index during bulk load, rebuild after (much faster at scale)
BENCH_PREPARE_ADOPT="${BENCH_PREPARE_ADOPT:-0}"  # 1 = build the PK index CONCURRENTLY (online, under load) before adopt, so adopt is metadata-only (essential at scale)

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
have_wal=0
have_pgfr=0
PGVERNUM=0
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

# total size of bench.events INCLUDING all partitions (a partitioned parent has no
# heap of its own, so pg_total_relation_size(parent) alone reads 0 post-conversion)
EVENTS_SIZE_SUB="(select pg_size_pretty(coalesce((select sum(pg_total_relation_size(c.oid)) from pg_class c
        where c.oid='bench.events'::regclass
           or c.oid in (select inhrelid from pg_inherits where inhparent='bench.events'::regclass)),0)))"

# health gauge: default size, dead tuples, live partition count, lag-ish counters
health_snapshot() {
  local label="$1"
  q "copy (
       select '$label' as phase,
              $EVENTS_SIZE_SUB as events_total_size,
              (select count(*) from pg_inherits where inhparent='bench.events'::regclass) as partitions,
              (select n_dead_tup from pg_stat_user_tables where relid='bench.events'::regclass) as parent_dead_tup,
              (select coalesce(sum(n_dead_tup),0) from pg_stat_user_tables
                 where schemaname='bench') as bench_dead_tup,
              (select count(*) from pg_stat_activity where state='active' and datname=current_database()) as active_backends
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.health.csv"
}

# WAL + checkpoint counters at a phase boundary (cumulative; the report diffs
# consecutive phases). Cheap counter reads, no superuser. pg_stat_wal is PG14+;
# checkpoint stats moved from pg_stat_bgwriter to pg_stat_checkpointer in PG17.
wal_snapshot() {
  [ "$have_wal" = "1" ] || return 0
  local label="$1" ckpt_count ckpt_buf
  if [ "$PGVERNUM" -ge 170000 ]; then
    ckpt_count="(select num_timed+num_requested from pg_stat_checkpointer)"
    ckpt_buf="(select buffers_written from pg_stat_checkpointer)"
  else
    ckpt_count="(select checkpoints_timed+checkpoints_req from pg_stat_bgwriter)"
    ckpt_buf="(select buffers_checkpoint from pg_stat_bgwriter)"
  fi
  q "copy (select '$label' as phase,
       (select pg_wal_lsn_diff(pg_current_wal_lsn(),'0/0')::bigint) as wal_bytes_total,
       (select wal_records from pg_stat_wal) as wal_records,
       (select wal_fpi from pg_stat_wal)     as wal_fpi,
       $ckpt_count as checkpoints,
       $ckpt_buf   as ckpt_buffers
     ) to stdout with (format csv, header true)" > "$RESULTS/$label.wal.csv" 2>/dev/null || true
}

# pg_flight_recorder per-phase capture: its continuous samples (WAL/checkpoint/IO
# deltas + wait events) tagged with the phase. select * because the view columns
# are pgfr's to define; guarded so a schema mismatch never aborts the run.
pgfr_snapshot() {
  [ "$have_pgfr" = "1" ] || return 0
  local label="$1"
  q "copy (select '$label'::text as phase, d.* from pgfr_record.deltas d) to stdout with (format csv, header true)" \
     > "$RESULTS/$label.pgfr_deltas.csv" 2>/dev/null || true
  q "copy (select '$label'::text as phase, w.* from pgfr_record.recent_waits w) to stdout with (format csv, header true)" \
     > "$RESULTS/$label.pgfr_waits.csv" 2>/dev/null || true
}

# markdown table of per-phase WAL/checkpoint deltas (each phase minus the prior boundary)
wal_report() {
  python3 - "$RESULTS" <<'PY'
import sys, os, csv
res = sys.argv[1]
order = ['_ref', 'baseline', 'prepare', 'adopt', 'drain', 'post']
rows = {}
for ph in order:
    p = os.path.join(res, f'{ph}.wal.csv')
    if os.path.exists(p):
        with open(p) as f:
            r = list(csv.DictReader(f))
            if r:
                rows[ph] = r[0]
def pretty(n):
    n = float(n)
    for u in ['B', 'KB', 'MB', 'GB', 'TB']:
        if abs(n) < 1024:
            return f'{n:.1f} {u}'
        n /= 1024
    return f'{n:.1f} PB'
cols = [('wal_bytes_total', 'WAL bytes'), ('wal_records', 'WAL records'),
        ('wal_fpi', 'WAL FPI'), ('checkpoints', 'checkpoints'), ('ckpt_buffers', 'ckpt buffers')]
have = [ph for ph in ['baseline', 'prepare', 'adopt', 'drain', 'post'] if ph in rows]
if not have:
    print('_(WAL/checkpoint gauges unavailable this run.)_')
    sys.exit(0)
print('| phase | ' + ' | '.join(c[1] for c in cols) + ' |')
print('|' + '---|' * (len(cols) + 1))
prev = '_ref' if '_ref' in rows else None
for ph in have:
    cells = []
    for key, _ in cols:
        cur = rows[ph].get(key)
        if cur in (None, ''):
            cells.append('n/a'); continue
        base = rows[prev].get(key) if (prev and prev in rows) else None
        d = float(cur) - float(base) if base not in (None, '') else float(cur)
        cells.append(pretty(d) if key == 'wal_bytes_total' else f'{int(d)}')
    print(f'| {ph} | ' + ' | '.join(cells) + ' |')
    prev = ph
PY
}

# percentiles (µs -> ms) from pgbench --log files for a label
pctiles() {
  local label="$1" files
  # pgbench --log-prefix=X writes "X.<pid>" and "X.<pid>.<thread>" (no .log suffix)
  files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a"; return 0; }
  # shellcheck disable=SC2086
  awk '{print $3}' $files | sort -n | awk '
    function pct(p,   i){ i=int(p*n); if(i>=n)i=n-1; return a[i]/1000.0 }
    { a[n++]=$1 }
    END {
      if (n==0) { print "n/a"; exit }
      printf "n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", n, pct(0.50), pct(0.95), pct(0.99), a[n-1]/1000.0
    }'
}

# run a fixed-duration load phase; capture pgbench summary + percentiles + pgss + health
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
  pgss_snapshot "$label"
  health_snapshot "$label"
  wal_snapshot "$label"
  pgfr_snapshot "$label"
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
PGVERNUM=$(q "show server_version_num" 2>/dev/null || echo 0)
# WAL/checkpoint gauges work without superuser as long as pg_monitor-ish reads are allowed
if q "select pg_wal_lsn_diff(pg_current_wal_lsn(),'0/0')" >/dev/null 2>&1 \
   && q "select wal_records from pg_stat_wal" >/dev/null 2>&1; then
  have_wal=1; echo "  WAL/checkpoint gauges: on (server_version_num=$PGVERNUM)"
else
  echo "  WAL/checkpoint gauges: unavailable (pg_current_wal_lsn/pg_stat_wal not readable)"
fi
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
      echo "  pg_flight_recorder: install/enable failed (needs pg_stat_statements preloaded) — continuing without pgfr"
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
  q "analyze bench.events" >/dev/null   # fresh stats after load (+ any index rebuild)
fi
qf "$BENCH_DIR/sql/20_workload.sql" >/dev/null
echo "  events: $(q "select count(*) from bench.events") rows, $(q "select pg_size_pretty(pg_total_relation_size('bench.events'))")"

# ---- 3. baseline (unpartitioned, under load) -------------------------------
run_start=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")   # for pgfr post-run report window
wal_snapshot _ref                                                # WAL/checkpoint reference point
run_phase baseline "$BENCH_PHASE_SECS"
assert_workload_healthy baseline   # bail now if the workload is timing out, before adopt/drain/post

# ---- 3b. prepare: build the PK index CONCURRENTLY under load (keeps adopt online) --
# pgpm.build_pk_concurrently() schedules the CIC as a pg_cron job and blocks (polling)
# until the index is valid -- entirely inside pgpm, no DDL handed back. We run it under
# live load to measure the online build's impact on the workload.
if [ "$BENCH_PREPARE_ADOPT" = "1" ]; then
  say "prepare adopt: build PK index CONCURRENTLY under load (pgpm.build_pk_concurrently, online)"
  pgss_reset
  rm -f "$RESULTS/pgb_prepare".*
  ( if [ -n "$BENCH_DSN" ]; then \
      "$PGBENCH" "$BENCH_DSN" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
        -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" --log "--log-prefix=$RESULTS/pgb_prepare"; \
    else \
      "$PGBENCH" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
        -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" --log "--log-prefix=$RESULTS/pgb_prepare"; \
    fi > "$RESULTS/prepare.pgbench.txt" 2>&1 ) &
  load_pid=$!; BG_PIDS+=("$load_pid")
  echo "  calling pgpm.build_pk_concurrently('bench.events','created_at') -- cron-driven online build..."
  prep_start=$(q "select extract(epoch from clock_timestamp())")
  q "call pgpm.build_pk_concurrently('bench.events','created_at')" >/dev/null
  prep_end=$(q "select extract(epoch from clock_timestamp())")
  kill "$load_pid" 2>/dev/null || true; wait "$load_pid" 2>/dev/null || true
  awk -v a="$prep_start" -v b="$prep_end" 'BEGIN{printf "  PK index built online in %.1fs (writes never blocked)\n", b-a}'
  pgss_snapshot prepare; health_snapshot prepare; wal_snapshot prepare; pgfr_snapshot prepare
  printf '%s\n' "$(pctiles prepare)" > "$RESULTS/prepare.pctiles.txt"
  echo "  latency during online build: $(cat "$RESULTS/prepare.pctiles.txt")"
fi

# ---- 4. adopt under load ---------------------------------------------------
say "adopt under load"
pgss_reset
rm -f "$RESULTS/pgb_adopt".*   # drop any prior-run logs so pctiles is fresh
adopt_bg_secs=$(( BENCH_ADOPT_WARM + 30 ))
( if [ -n "$BENCH_DSN" ]; then \
    "$PGBENCH" "$BENCH_DSN" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$adopt_bg_secs" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_adopt"; \
  else \
    "$PGBENCH" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$adopt_bg_secs" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_adopt"; \
  fi > "$RESULTS/adopt.pgbench.txt" 2>&1 ) &
load_pid=$!; BG_PIDS+=("$load_pid")
sleep "$BENCH_ADOPT_WARM"
echo "  firing pgpm.adopt('bench.events','created_at','$BENCH_INTERVAL') under live load..."
adopt_start=$(q "select extract(epoch from clock_timestamp())")
q "select pgpm.adopt('bench.events','created_at', interval '$BENCH_INTERVAL', $BENCH_PREMAKE)" >/dev/null
adopt_end=$(q "select extract(epoch from clock_timestamp())")
awk -v a="$adopt_start" -v b="$adopt_end" 'BEGIN{printf "  adopt() returned in %.3fs (metadata-only; table is now partitioned)\n", b-a}'
wait "$load_pid" || true
pgss_snapshot adopt
health_snapshot adopt
wal_snapshot adopt
pgfr_snapshot adopt
printf '%s\n' "$(pctiles adopt)" > "$RESULTS/adopt.pctiles.txt"
echo "  default holds: $(q "select coalesce(n_live_tup,0)::bigint from pg_stat_user_tables where relid='bench.events_default'::regclass") rows to drain"

# ---- 5. drain under load ---------------------------------------------------
say "drain under load"
pgss_reset
rm -f "$RESULTS/pgb_drain".*   # drop any prior-run logs so pctiles is fresh
( if [ -n "$BENCH_DSN" ]; then \
    "$PGBENCH" "$BENCH_DSN" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_drain"; \
  else \
    "$PGBENCH" -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$BENCH_DRAIN_MAX_SECS" -P 5 \
      -D "ops=$BENCH_OPS" -f "$BENCH_DIR/workload.pgbench" \
      --log "--log-prefix=$RESULTS/pgb_drain"; \
  fi > "$RESULTS/drain.pgbench.txt" 2>&1 ) &
load_pid=$!; BG_PIDS+=("$load_pid")
drain_start=$(q "select extract(epoch from clock_timestamp())")
: > "$RESULTS/drain.progress.csv"
# default_rows_est is pg_stat_user_tables.n_live_tup (instant estimate) -- an exact
# count(*) over the default is a full scan (100s+ at scale) and would dominate the loop.
echo "elapsed_s,default_rows_est,partitions,status" >> "$RESULTS/drain.progress.csv"
steps=0
while :; do
  status=$(q "select pgpm.drain_step('bench.events', $BENCH_DRAIN_BATCH)")
  steps=$((steps + 1))
  if [ $((steps % 10)) -eq 0 ] || [ "${status%%:*}" = "attached" ]; then
    now_s=$(q "select extract(epoch from clock_timestamp())")
    elapsed=$(awk -v a="$drain_start" -v b="$now_s" 'BEGIN{printf "%.0f", b-a}')
    drows=$(q "select coalesce(n_live_tup,0)::bigint from pg_stat_user_tables where relid='bench.events_default'::regclass")
    nparts=$(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")
    printf '%s,%s,%s,%s\n' "$elapsed" "$drows" "$nparts" "$status" >> "$RESULTS/drain.progress.csv"
    printf '\r  drain: %ss elapsed, default=%s rows, %s partitions, last=%s   ' \
      "$elapsed" "$drows" "$nparts" "$status"
  fi
  [ "$status" = "idle" ] && break
  now_s=$(q "select extract(epoch from clock_timestamp())")
  if awk -v a="$drain_start" -v b="$now_s" -v m="$BENCH_DRAIN_MAX_SECS" 'BEGIN{exit !(b-a > m)}'; then
    echo; echo "  drain hit BENCH_DRAIN_MAX_SECS cap; stopping"; break
  fi
  [ "$BENCH_DRAIN_SLEEP" != "0" ] && sleep "$BENCH_DRAIN_SLEEP" || true
done
drain_end=$(q "select extract(epoch from clock_timestamp())")
echo
awk -v a="$drain_start" -v b="$drain_end" -v s="$steps" \
  'BEGIN{printf "  drain complete: %d steps in %.1fs (closed history fully partitioned)\n", s, b-a}'
kill "$load_pid" 2>/dev/null || true
wait "$load_pid" 2>/dev/null || true
pgss_snapshot drain
health_snapshot drain
wal_snapshot drain
pgfr_snapshot drain
printf '%s\n' "$(pctiles drain)" > "$RESULTS/drain.pctiles.txt"

# ---- 6. post (partitioned, under load) -------------------------------------
# Reclaim the dead tuples the drain left in the default before measuring: "after
# conversion" steady state has a vacuumed default, not the drain's transient bloat.
say "vacuum + analyze before post (settle the conversion)"
q "vacuum (analyze) bench.events" >/dev/null
run_phase post "$BENCH_PHASE_SECS"

# ---- 7. report -------------------------------------------------------------
say "report"
{
  echo "# pg_partition_magician — at-scale load test"
  echo
  echo "- rows: $(q "select count(*) from bench.events")"
  echo "- events size: $(q "select $EVENTS_SIZE_SUB")"
  echo "- partitions: $(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")"
  echo "- clients: $BENCH_CLIENTS, ops/call: $BENCH_OPS, drain batch: $BENCH_DRAIN_BATCH"
  echo
  echo "## throughput / latency by phase"
  echo
  echo "| phase | pgbench tps | pgbench avg latency | server-side latency (pgbench --log) |"
  echo "|-------|-------------|---------------------|--------------------------------------|"
  for ph in baseline prepare adopt drain post; do
    tps=$(grep -h 'tps =' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || echo "n/a")
    lat=$(grep -h 'latency average' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || echo "n/a")
    pct=$(cat "$RESULTS/$ph.pctiles.txt" 2>/dev/null || echo "n/a")
    printf '| %s | %s | %s | %s |\n' "$ph" "${tps:-n/a}" "${lat:-n/a}" "$pct"
  done
  echo
  echo "## health by phase"
  echo
  if [ -f "$RESULTS/baseline.health.csv" ]; then
    head -1 "$RESULTS/baseline.health.csv" | sed 's/,/ | /g; s/^/| /; s/$/ |/'
    head -1 "$RESULTS/baseline.health.csv" | sed 's/[^,]*/---/g; s/,/ | /g; s/^/| /; s/$/ |/'
    for ph in baseline prepare adopt drain post; do
      [ -f "$RESULTS/$ph.health.csv" ] && tail -1 "$RESULTS/$ph.health.csv" | sed 's/,/ | /g; s/^/| /; s/$/ |/'
    done
  fi
  echo
  echo "## WAL / checkpoint by phase (deltas)"
  echo
  wal_report
  echo
  if [ "$have_pgfr" = "1" ]; then
    echo "## pg_flight_recorder"
    echo
    echo "Per-phase wait events / activity / snapshot deltas: \`*.pgfr_deltas.csv\`, \`*.pgfr_waits.csv\`."
    echo "Full-run narrative: \`pgfr_report.md\`."
  fi
  echo
  echo "## drain progress"
  echo
  echo "See \`drain.progress.csv\` (default_rows draining to ~current-month residue under load)."
  echo
  echo "Per-statement server-side timing per phase: \`*.pgss.csv\`."
} > "$RESULTS/report.md"

# pg_flight_recorder full-run narrative (analyze) + stop collection
if [ "$have_pgfr" = "1" ]; then
  run_end=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")
  q "select pgfr_analyze.report('1 hour')" > "$RESULTS/pgfr_report.md" 2>/dev/null \
    || q "select pgfr_analyze.incident_timeline('$run_start','$run_end')" > "$RESULTS/pgfr_report.md" 2>/dev/null \
    || echo "(pgfr_analyze report unavailable)" > "$RESULTS/pgfr_report.md"
  q "select pgfr_record.disable()" >/dev/null 2>&1 || true
fi

cat "$RESULTS/report.md"
echo
echo "Full artifacts in $RESULTS/"
