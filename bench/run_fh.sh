#!/usr/bin/env bash
# At-scale load test for pg_partition_magician's from_hypertable path.
#
# Where bench/run.sh converts a plain id-table with transmute+regrain, THIS harness converts a TimescaleDB
# HYPERTABLE (Apache) via from_hypertable, under live OLTP load, and measures latency/throughput before,
# during, and after. Three phases:
#   1. baseline -- ambient workload against the live hypertable.
#   2. convert  -- from_hypertable_copy (online copy into one plain table, chunk by chunk, source live) under load WITH p_track_changes
#                  (a trigger logs in-flight insert/update/delete), then from_hypertable_cutover (brief lock,
#                  catch-up + reconcile, drop the hypertable, hand off to transmute), then -- if BENCH_REGRAIN
#                  -- regrain the resulting time-monolith into fine partitions via scheduled pgpm.maintain.
#   3. post     -- ambient workload against the now pgpm-partitioned table.
# Conservation under continuous load is checked via an IMMUTABLE cohort the workload never touches
# (users 49001..50000; see bench/sql/20_workload_fh.sql): it must survive the online migration unchanged.
#
# Everything is parameterised by env vars; the connection string is NEVER echoed.
set -euo pipefail

PSQL="${PSQL:-psql}"
PGBENCH="${PGBENCH:-pgbench}"
BENCH_DSN="${BENCH_DSN:-}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BENCH_DIR="$REPO_ROOT/bench"
RESULTS="${RESULTS:-$BENCH_DIR/results/fh}"

BENCH_ROWS="${BENCH_ROWS:-4000000}"            # target rows in the hypertable
BENCH_MONTHS="${BENCH_MONTHS:-6}"              # history spread across this many months
BENCH_CHUNK="${BENCH_CHUNK:-2000000}"          # generator commit chunk (rows)
BENCH_GEN_JOBS="${BENCH_GEN_JOBS:-1}"          # parallel generator sessions (~vCPU)
BENCH_CHUNK_INTERVAL="${BENCH_CHUNK_INTERVAL:-1 week}"  # HYPERTABLE chunk width (-> #chunks the copy iterates)
BENCH_FH_INTERVAL="${BENCH_FH_INTERVAL:-1 month}"       # pgpm partition width from_hypertable transmutes to

BENCH_CLIENTS="${BENCH_CLIENTS:-8}"
BENCH_JOBS="${BENCH_JOBS:-4}"
BENCH_OPS="${BENCH_OPS:-10}"
BENCH_PHASE_SECS="${BENCH_PHASE_SECS:-30}"
BENCH_MAX_FAIL_PCT="${BENCH_MAX_FAIL_PCT:-5}"

BENCH_TRACK_CHANGES="${BENCH_TRACK_CHANGES:-1}" # 1 = p_track_changes (capture in-flight upd/del during copy)
BENCH_OBTAIN="${BENCH_OBTAIN:-4}"
BENCH_DRAIN_BATCH="${BENCH_DRAIN_BATCH:-50000}"
BENCH_REGRAIN="${BENCH_REGRAIN:-1}"               # 1 = regrain the resulting monolith to BENCH_FH_INTERVAL
BENCH_MAINT_INTERVAL="${BENCH_MAINT_INTERVAL:-2 seconds}"
BENCH_OBSERVE_INTERVAL="${BENCH_OBSERVE_INTERVAL:-10}"
BENCH_DRAIN_MAX_SECS="${BENCH_DRAIN_MAX_SECS:-1800}"   # cap on the regrain observation window

# #170 cutover-lock-window arm: BENCH_PREDRAIN toggles the cutover's online pre-drain (1 = drained,
# p_predrain=>true; 0 = undrained, p_predrain=>false). Run a rung twice (1 vs 0) on FRESH instances and
# compare the "cutover lock window" report section. BENCH_LOCKPROBE arms a background pg_locks session that
# times the TRUE ACCESS EXCLUSIVE window (vs the whole cutover call) and reads the at-lock delta residual.
BENCH_PREDRAIN="${BENCH_PREDRAIN:-1}"
BENCH_LOCKPROBE="${BENCH_LOCKPROBE:-1}"

BENCH_PGFR="${BENCH_PGFR:-0}"
BENCH_PGFR_DIR="${BENCH_PGFR_DIR:-$BENCH_DIR/vendor/pg_flight_recorder}"
BENCH_SKIP_GENERATE="${BENCH_SKIP_GENERATE:-0}"

ANCHOR_USER_LO=49001    # the immutable conservation cohort: users 49001..50000 (matches 20_workload_fh.sql)

# TCP keepalives on every connection (libpq defaults them OFF) -- a long synchronous from_hypertable_copy
# sits idle on the wire while the backend works; over a NAT'd/pooler path an idle flow gets reaped.
if [ -n "$BENCH_DSN" ] && [[ "$BENCH_DSN" != *keepalives=* ]]; then
  if [[ "$BENCH_DSN" == *\?* ]]; then BENCH_DSN="$BENCH_DSN&"; else BENCH_DSN="$BENCH_DSN?"; fi
  BENCH_DSN="${BENCH_DSN}keepalives=1&keepalives_idle=5&keepalives_interval=5&keepalives_count=6"
fi

mkdir -p "$RESULTS"
BG_PIDS=()
cleanup() { local p; for p in "${BG_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

TO_OFF="set statement_timeout=0; set lock_timeout=0"
q()  { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -tAq -c "$TO_OFF" -c "$1"; fi; }
qf() { if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -c "$TO_OFF" -f "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -c "$TO_OFF" -f "$1"; fi; }
qf1(){ if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -c "$TO_OFF" --single-transaction -f "$1"; else "$PSQL" -v ON_ERROR_STOP=1 -c "$TO_OFF" --single-transaction -f "$1"; fi; }
say() { printf '\n\033[1;36m== %s ==\033[0m %s\n' "$1" "$(q "select to_char(now(),'HH24:MI:SS')")"; }
have_ext() { [ "$(q "select count(*) from pg_extension where extname='$1'")" = "1" ]; }
have_pgss=0; have_pgfr=0

pgss_reset() { [ "$have_pgss" = "1" ] && q "select pg_stat_statements_reset()" >/dev/null || true; }
pgss_snapshot() {
  [ "$have_pgss" = "1" ] || return 0; local label="$1"
  q "copy (select '$label' as phase, calls, round(total_exec_time::numeric,1) total_ms,
            round(mean_exec_time::numeric,4) mean_ms, rows,
            left(regexp_replace(query,'\s+',' ','g'),80) query
       from pg_stat_statements where query ilike '%bench.%' and query not ilike '%pg_stat_statements%'
       order by total_exec_time desc limit 15) to stdout with (format csv, header true)" > "$RESULTS/$label.pgss.csv"
}

# client p50/p95/p99/max from the pgbench --log (µs -> ms)
pctiles() {
  local label="$1" files; files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a"; return 0; }
  # shellcheck disable=SC2086
  awk '{print $3}' $files | sort -n | awk '
    function pct(p,   i){ i=int(p*n); if(i>=n)i=n-1; return a[i]/1000.0 }
    { a[n++]=$1 } END { if(n==0){print "n/a"; exit}
      printf "n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", n, pct(.50), pct(.95), pct(.99), a[n-1]/1000.0 }'
}
pgbench_log_summary() {
  local label="$1" files; files=$(ls "$RESULTS/pgb_$label".* 2>/dev/null || true)
  [ -n "$files" ] || { echo "n/a|n/a"; return 0; }
  # shellcheck disable=SC2086
  awk '$5+0 > 1000000000 { n++; lat+=$3; t=$5+$6/1e6; if(mn==0||t<mn)mn=t; if(t>mx)mx=t }
       END{ if(n==0){print "n/a|n/a"; exit} el=mx-mn; if(el<=0)el=1;
            printf "tps = %.1f (from --log)|latency average = %.1f ms", n/el, (lat/n)/1000.0 }' $files
}

run_phase() {
  local label="$1" secs="$2"
  say "load phase: $label (${secs}s, ${BENCH_CLIENTS} clients)"
  pgss_reset
  local args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$secs" -P 5
               -D "ops=$BENCH_OPS" -D "clock_secs=0" -f "$BENCH_DIR/workload_fh.pgbench"
               --log "--log-prefix=$RESULTS/pgb_$label" )
  rm -f "$RESULTS/pgb_$label".*
  if [ -n "$BENCH_DSN" ]; then "$PGBENCH" "$BENCH_DSN" "${args[@]}"; else "$PGBENCH" "${args[@]}"; fi \
    | tee "$RESULTS/$label.pgbench.txt"
  pgss_snapshot "$label"
  printf '%s\n' "$(pctiles "$label")" > "$RESULTS/$label.pctiles.txt"
  echo "  latency: $(cat "$RESULTS/$label.pctiles.txt")"
}

assert_workload_healthy() {
  local label="$1" f tps
  f=$(grep -oE 'number of failed transactions: [0-9]+ \([0-9.]+%\)' "$RESULTS/$label.pgbench.txt" 2>/dev/null | grep -oE '[0-9.]+%' | head -1 | tr -d '%')
  tps=$(grep -oE 'tps = [0-9.]+' "$RESULTS/$label.pgbench.txt" 2>/dev/null | head -1 | grep -oE '[0-9.]+')
  f=${f:-100}; tps=${tps:-0}
  if awk -v f="$f" -v m="$BENCH_MAX_FAIL_PCT" 'BEGIN{exit !(f+0 > m+0)}'; then
    echo "  ABORT: ${f}% of '$label' transactions FAILED (> ${BENCH_MAX_FAIL_PCT}%). Lower BENCH_OPS and re-run."; exit 2
  fi
  echo "  workload health OK ($label: ${f}% failed, ${tps} tps)"
}

# ---- 0. preflight ----
say "preflight"
q "select version()" | sed 's/^/  /'
if ! have_ext timescaledb; then
  q "create extension if not exists timescaledb" >/dev/null 2>&1 || { echo "  ERROR: timescaledb required (PG15 Apache)"; exit 1; }
fi
echo "  timescaledb: $(q "select extversion from pg_extension where extname='timescaledb'") (license $(q "show timescaledb.license" 2>/dev/null || echo '?'))"
if ! have_ext pg_cron; then
  q "create extension if not exists pg_cron" >/dev/null 2>&1 || { echo "  ERROR: pg_cron required"; exit 1; }
fi
if q "create extension if not exists pg_stat_statements" >/dev/null 2>&1 && q "select pg_stat_statements_reset()" >/dev/null 2>&1; then
  have_pgss=1; echo "  pg_stat_statements: on"
else echo "  pg_stat_statements: unavailable"; fi

# ---- 1. install pgpm + from_hypertable ----
say "install pg_partition_magician + from_hypertable"
qf "$REPO_ROOT/pgpm_core/install.sql" >/dev/null
qf "$REPO_ROOT/pgpm_hypertable/install.sql" >/dev/null
echo "  pgpm: $(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgpm'") functions; from_hypertable present: $(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgpm' and p.proname='from_hypertable'")"
if [ "$BENCH_PGFR" = "1" ] && [ -f "$BENCH_PGFR_DIR/pgfr_record/install.sql" ]; then
  say "install pg_flight_recorder"
  if qf1 "$BENCH_PGFR_DIR/pgfr_record/install.sql" >/dev/null 2>&1 && q "select pgfr_record.enable()" >/dev/null 2>&1; then
    qf1 "$BENCH_PGFR_DIR/pgfr_analyze/install.sql" >/dev/null 2>&1 || true
    q "select pgfr_record.apply_profile('troubleshooting')" >/dev/null 2>&1 || true
    have_pgfr=1; echo "  pgfr enabled"
  else echo "  pgfr install/enable failed; continuing"; fi
fi

# ---- 2. schema (hypertable) + generate ----
if [ "$BENCH_SKIP_GENERATE" = "1" ]; then
  say "skip generate (BENCH_SKIP_GENERATE=1)"
else
  say "build hypertable schema + generate $BENCH_ROWS rows server-side (chunk_interval='$BENCH_CHUNK_INTERVAL')"
  if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -q -c "$TO_OFF" -v chunk_interval="$BENCH_CHUNK_INTERVAL" -f "$BENCH_DIR/sql/00_schema_fh.sql" >/dev/null;
  else "$PSQL" -v ON_ERROR_STOP=1 -q -c "$TO_OFF" -v chunk_interval="$BENCH_CHUNK_INTERVAL" -f "$BENCH_DIR/sql/00_schema_fh.sql" >/dev/null; fi
  qf "$BENCH_DIR/sql/10_generate.sql" >/dev/null
  if [ "$BENCH_GEN_JOBS" -le 1 ]; then
    q "call bench.generate_events($BENCH_ROWS, $BENCH_MONTHS, $BENCH_CHUNK)"
  else
    gen_base=$(( BENCH_ROWS / BENCH_GEN_JOBS )); gen_rem=$(( BENCH_ROWS - gen_base * BENCH_GEN_JOBS )); gen_pids=()
    for j in $(seq 1 "$BENCH_GEN_JOBS"); do
      rows_j=$gen_base; [ "$j" -eq 1 ] && rows_j=$(( gen_base + gen_rem ))
      ( q "call bench.generate_events($rows_j, $BENCH_MONTHS, $BENCH_CHUNK)" > "$RESULTS/generate_job_$j.log" 2>&1 ) &
      pid=$!; gen_pids+=("$pid"); BG_PIDS+=("$pid")
    done
    gf=0; for pid in "${gen_pids[@]}"; do wait "$pid" || gf=1; done
    [ "$gf" = "0" ] || { echo "  ERROR: a generator failed; see $RESULTS/generate_job_*.log"; exit 1; }
  fi
  q "analyze bench.events" >/dev/null
fi
qf "$BENCH_DIR/sql/20_workload_fh.sql" >/dev/null
echo "  events: $(q "select count(*) from bench.events") rows in $(q "select count(*) from timescaledb_information.chunks where hypertable_name='events'") chunks, $(q "select pg_size_pretty(pg_total_relation_size('bench.events'))")"

# ---- 3. baseline (live hypertable) ----
run_phase baseline "$BENCH_PHASE_SECS"
assert_workload_healthy baseline

# ---- 4. convert: from_hypertable under load ----
say "conversion: from_hypertable_copy under load (track_changes=$BENCH_TRACK_CHANGES) -> cutover -> regrain"
pgss_reset; rm -f "$RESULTS/pgb_convert".*
TRACK=$([ "$BENCH_TRACK_CHANGES" = "1" ] && echo true || echo false)
ANCHOR0=$(q "select count(*) from bench.events where user_id >= $ANCHOR_USER_LO")   # immutable cohort, pre-convert
echo "  conservation anchor: $ANCHOR0 rows for users >= $ANCHOR_USER_LO (workload never touches them)"
convert_start=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")

# 4a. start the continuous ambient workload (inserts + updates + deletes for users < anchor)
conv_args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$(( BENCH_DRAIN_MAX_SECS + 1200 ))" -P 5
            -D "ops=$BENCH_OPS" -D "clock_secs=0" -f "$BENCH_DIR/workload_fh.pgbench" --log "--log-prefix=$RESULTS/pgb_convert" )
if [ -n "$BENCH_DSN" ]; then "$PGBENCH" "$BENCH_DSN" "${conv_args[@]}" > "$RESULTS/convert.pgbench.txt" 2>&1 &
else "$PGBENCH" "${conv_args[@]}" > "$RESULTS/convert.pgbench.txt" 2>&1 & fi
load_pid=$!; BG_PIDS+=("$load_pid")
sleep 3   # let the workload warm up so writes are in flight before the copy starts

# 4b. PHASE 1 (from_hypertable_copy) in the background, so we can observe the online copy progress
echo "  firing from_hypertable_copy('bench.events','created_at', p_track_changes => $TRACK)..."
copy_t0=$(q "select extract(epoch from clock_timestamp())")
( q "call pgpm.from_hypertable_copy('bench.events','created_at', p_track_changes => $TRACK)" ) > "$RESULTS/copy.log" 2>&1 &
copy_pid=$!; BG_PIDS+=("$copy_pid")
: > "$RESULTS/copy.progress.csv"; echo "elapsed_s,dest_rows,delta_rows" >> "$RESULTS/copy.progress.csv"
while kill -0 "$copy_pid" 2>/dev/null; do
  sleep "$BENCH_OBSERVE_INTERVAL"
  el=$(awk -v a="$copy_t0" -v b="$(q "select extract(epoch from clock_timestamp())")" 'BEGIN{printf "%.0f", b-a}')
  dest=$(q "select coalesce((select count(*) from bench.events_pgpm_dest),0)" 2>/dev/null || echo "?")
  delta=$(q "select coalesce((select count(*) from bench.events_pgpm_delta),0)" 2>/dev/null || echo "0")
  printf '%s,%s,%s\n' "$el" "$dest" "$delta" >> "$RESULTS/copy.progress.csv"
  printf '\r  copy: %ss, dest_rows=%s, delta=%s   ' "$el" "$dest" "$delta"
done
echo
if ! wait "$copy_pid"; then echo "  ERROR: from_hypertable_copy failed:"; tail -5 "$RESULTS/copy.log"; exit 1; fi
copy_secs=$(awk -v a="$copy_t0" -v b="$(q "select extract(epoch from clock_timestamp())")" 'BEGIN{printf "%.1f", b-a}')
# capture the dest size + the catch-up backlog BEFORE cutover (cutover drops/consumes it, so reading after
# always reports 0 -- a stale-read trap). The backlog is path-dependent: with change tracking it is the
# delta row count; on the append-only path there is NO delta table, so it is the count of source rows past
# the copy watermark (control > max(dest)). (The earlier unconditional delta read errored on the
# append-only path, where bench.events_pgpm_delta does not exist.)
DEST_ROWS=$(q "select count(*) from bench.events_pgpm_dest")
if [ "$(q "select (to_regclass('bench.events_pgpm_delta') is not null)::text")" = "t" ]; then
  DELTA_PENDING=$(q "select count(*) from bench.events_pgpm_delta")
  echo "  copy complete in ${copy_secs}s (dest holds $DEST_ROWS rows; $DELTA_PENDING in-flight delta keys to reconcile at cutover)"
else
  DELTA_PENDING=$(q "select count(*) from bench.events where created_at > coalesce((select max(created_at) from bench.events_pgpm_dest), to_timestamp(0))")
  echo "  copy complete in ${copy_secs}s (dest holds $DEST_ROWS rows; $DELTA_PENDING appended rows past the watermark to catch up at cutover)"
fi

# 4c. PHASE 2 (cutover): brief lock, catch up + reconcile, drop hypertable, hand off to transmute.
# #170: optionally pre-drain the delta ONLINE before the lock (p_predrain), and time the TRUE ACCESS
# EXCLUSIVE window with a background pg_locks probe (the whole cutover call also includes the online
# pre-drain + the O(rows) index pre-build, so cut_secs overstates the blocking window).
PREDRAIN=$([ "$BENCH_PREDRAIN" = "1" ] && echo true || echo false)
LOCK_WINDOW_S="n/a"; probe_pid=""
# the at-lock residual the under-lock reconcile applies: the whole captured backlog when undrained, or
# threshold-bounded when the pre-drain ran. (Not probed -- a probe reading the delta would lock it and
# block the cutover's drop; see the probe note above.)
if [ "$BENCH_PREDRAIN" = "1" ]; then AT_LOCK_RESIDUAL="<= $BENCH_DRAIN_BATCH (pre-drain threshold)"; else AT_LOCK_RESIDUAL="$DELTA_PENDING (whole backlog; no pre-drain)"; fi
if [ "$BENCH_LOCKPROBE" = "1" ]; then
  # Server-side probe: ONE session brackets the source's AccessExclusiveLock (pg_locks is a live, non-MVCC
  # view, so re-querying within the one txn sees the lock appear/vanish). It reads ONLY pg_locks -- never the
  # source OR the delta -- so it takes no relation lock that the cutover needs: reading the delta here would
  # hold AccessShare on it for the whole probe txn and DEADLOCK the cutover's drop of the delta. The at-lock
  # residual is reported separately (DELTA_PENDING for undrained; threshold-bounded for drained), not probed.
  cat > "$RESULTS/lockprobe.sql" <<'SQL'
set statement_timeout=0; set lock_timeout=0; set client_min_messages=notice;
do $probe$
declare
  v_src oid := ('bench.events'::regclass)::oid;
  v_held boolean; v_acq timestamptz; v_rel timestamptz;
  v_deadline timestamptz := clock_timestamp() + interval '2 hours';   -- backstop; the harness stops the probe right after the cutover
begin
  loop   -- wait for the cutover to take ACCESS EXCLUSIVE on the source
    select exists(select 1 from pg_locks where relation=v_src and mode='AccessExclusiveLock' and granted) into v_held;
    exit when v_held;
    if clock_timestamp() > v_deadline then raise notice 'LOCKPROBE status=timeout-no-acquire'; return; end if;
    perform pg_sleep(0.02);
  end loop;
  v_acq := clock_timestamp();
  loop   -- wait for release (the swap committed -> lock gone / relation dropped)
    select exists(select 1 from pg_locks where relation=v_src and mode='AccessExclusiveLock' and granted) into v_held;
    exit when not v_held;
    perform pg_sleep(0.01);
  end loop;
  v_rel := clock_timestamp();
  raise notice 'LOCKPROBE status=ok window_s=%', round(extract(epoch from (v_rel - v_acq))::numeric, 3);
end
$probe$;
SQL
  if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=0 -f "$RESULTS/lockprobe.sql" > "$RESULTS/lockprobe.log" 2>&1 &
  else "$PSQL" -v ON_ERROR_STOP=0 -f "$RESULTS/lockprobe.sql" > "$RESULTS/lockprobe.log" 2>&1 & fi
  probe_pid=$!; BG_PIDS+=("$probe_pid")
  sleep 0.5   # let the probe start polling before the cutover takes its lock
fi
echo "  firing from_hypertable_cutover('bench.events','created_at', interval '$BENCH_FH_INTERVAL', p_predrain => $PREDRAIN, p_paused => false)..."
cut_t0=$(q "select extract(epoch from clock_timestamp())")
q "call pgpm.from_hypertable_cutover('bench.events','created_at', interval '$BENCH_FH_INTERVAL', p_obtain => $BENCH_OBTAIN, p_drain_batch => $BENCH_DRAIN_BATCH, p_paused => false, p_predrain => $PREDRAIN)" >/dev/null
cut_secs=$(awk -v a="$cut_t0" -v b="$(q "select extract(epoch from clock_timestamp())")" 'BEGIN{printf "%.1f", b-a}')
echo "  cutover complete in ${cut_secs}s -- bench.events is now relkind '$(q "select relkind from pg_class where oid='bench.events'::regclass")' (p=partitioned)"
if [ -n "$probe_pid" ]; then
  # The lock is released by the time the cutover call returns, so a probe that caught it has already exited;
  # give it a moment to flush its NOTICE, then stop it (a sub-resolution window it MISSED would otherwise
  # spin on its acquire-wait until the backstop, so never wait unbounded).
  for _ in $(seq 1 15); do kill -0 "$probe_pid" 2>/dev/null || break; sleep 0.2; done
  kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true
  probe_line=$(grep 'LOCKPROBE' "$RESULTS/lockprobe.log" 2>/dev/null | tail -1)
  if printf '%s' "$probe_line" | grep -q 'status=ok'; then
    LOCK_WINDOW_S=$(printf '%s' "$probe_line" | grep -oE 'window_s=[0-9.]+' | cut -d= -f2)
  else
    LOCK_WINDOW_S="n/a"; echo "  (lock probe: ${probe_line:-no output; the window may have been below the probe poll resolution})"
  fi
  echo "  cutover ACCESS EXCLUSIVE window: ${LOCK_WINDOW_S}s  (at-lock residual: ${AT_LOCK_RESIDUAL}; whole cutover call ${cut_secs}s)"
fi

# 4d. conservation: the immutable cohort must be unchanged through the online migration
ANCHOR1=$(q "select count(*) from bench.events where user_id >= $ANCHOR_USER_LO")
if [ "$ANCHOR0" = "$ANCHOR1" ]; then echo "  CONSERVATION OK: anchor cohort $ANCHOR0 == $ANCHOR1 (no rows lost/duplicated through the online migration)"; CONS=ok
else echo "  CONSERVATION FAIL: anchor cohort $ANCHOR0 -> $ANCHOR1 (rows lost/duplicated). CORRECTNESS DEFECT."; CONS=fail; fi
HT_LEFT=$(q "select count(*) from timescaledb_information.hypertables where hypertable_name='events'")
echo "  hypertable catalog rows for 'events' remaining: $HT_LEFT (expect 0)"

# end the convert measurement window (copy + cutover) -- stop the now()-load and capture its client metrics
kill "$load_pid" 2>/dev/null || true; wait "$load_pid" 2>/dev/null || true
pgss_snapshot convert
printf '%s\n' "$(pctiles convert)" > "$RESULTS/convert.pctiles.txt"
echo "  ambient-workload latency through copy+cutover: $(cat "$RESULTS/convert.pctiles.txt")"

# 4e. regrain the resulting time-monolith. A time monolith [min, hi] only freezes once the write frontier
# passes hi -- under live current-period writes it never would (the inherent time-key limitation). So advance
# the frontier with a sentinel past hi and run a FUTURE-CLOCK workload that writes into forward partitions
# (above hi): the realistic "ongoing writes land in the new period while pgpm regrains the migrated history"
# shape, and the only way a time monolith can freeze in-window.
REGRAIN_COARSE_FINAL=na
if [ "$BENCH_REGRAIN" = "1" ]; then
  MONO_HI=$(q "select hi from pgpm.part where parent_table='bench.events'::regclass and attached order by lo::timestamptz asc limit 1")
  CLK=$(q "select (ceil(extract(epoch from ('$MONO_HI'::timestamptz - now()))) + 8*86400)::bigint")   # past hi + a full read window
  SKEW_TS=$(q "select to_char(('$MONO_HI'::timestamptz + interval '40 days'),'YYYY-MM-DD HH24:MI:SS+00')")
  say "regrain the monolith (< $MONO_HI) to '$BENCH_FH_INTERVAL'"
  echo "  a time monolith frees only when wall-clock now() passes its upper bound, so under live load it never"
  echo "  would. The ambient load runs at an effective clock +${CLK}s (forward partitions, past the monolith),"
  echo "  so the monolith range receives NO writes; regrain is then driven in a now()-shadowed session -- a BENCH"
  echo "  INSTRUMENT that lets pgpm act on the genuinely-quiescent historical monolith as if frozen. Never in prod."
  q "select pgpm.obtain('bench.events')" >/dev/null
  q "select pgpm.set_regrain('bench.events', '$BENCH_FH_INTERVAL')" >/dev/null
  q "select pgpm.set_drain_adaptive('bench.events', true)" >/dev/null
  # ongoing load on forward partitions (keeps the monolith quiescent during the skewed regrain)
  regrain_args=( -n -c "$BENCH_CLIENTS" -j "$BENCH_JOBS" -T "$(( BENCH_DRAIN_MAX_SECS + 120 ))" -P 5
                -D "ops=$BENCH_OPS" -D "clock_secs=$CLK" -f "$BENCH_DIR/workload_fh.pgbench" --log "--log-prefix=$RESULTS/pgb_regrain" )
  if [ -n "$BENCH_DSN" ]; then "$PGBENCH" "$BENCH_DSN" "${regrain_args[@]}" > "$RESULTS/regrain.pgbench.txt" 2>&1 &
  else "$PGBENCH" "${regrain_args[@]}" > "$RESULTS/regrain.pgbench.txt" 2>&1 & fi
  regrain_load_pid=$!; BG_PIDS+=("$regrain_load_pid")
  # Drive regrain DIRECTLY in a now()-shadowed session (NOT via cron: pg_cron's maintain runs with the real
  # now() and would see the monolith as the active current partition, so it never regrains it). pgpm functions
  # do not pin search_path, so a shadow.now() ahead of pg_catalog overrides now() inside regrain_step's freeze
  # check. We drive regrain_STEP per batch with COMMIT between batches -- NOT regrain()/regrain_history(), which
  # are FUNCTIONS that loop to completion in ONE transaction (at scale that single txn accumulates
  # uncheckpointable WAL and a giant lock, and shows no progress until it commits). Per-batch commit is
  # pgpm's own incremental model (what its cron maintain does), so WAL recycles, the disk stays bounded on
  # the big rungs, and regrain progress is visible as it goes.
  cat > "$RESULTS/regrain_skewed.sql" <<SQL
set statement_timeout=0;
create schema if not exists pgpm_bench_shadow;
create or replace function pgpm_bench_shadow.now() returns timestamptz language sql as \$fn\$ select timestamptz '$SKEW_TS' \$fn\$;
set search_path = pgpm_bench_shadow, pg_catalog, public, pgpm;
do \$drv\$
declare v_mon name; v_status text; v_ncast text; v_steps int := 0;
begin
  select pgpm._native_type(control_kind) into v_ncast from pgpm.config where parent_table='bench.events'::regclass;
  execute format('select child_name from pgpm.part where parent_table=%L::regclass and attached order by lo::%s asc limit 1','bench.events',v_ncast) into v_mon;
  if v_mon is null then raise exception 'regrain driver: no attached monolith to regrain'; end if;
  loop
    v_status := pgpm.regrain_step('bench.events', v_mon, '$BENCH_FH_INTERVAL', null);
    commit;
    v_steps := v_steps + 1;
    exit when v_status like 'swapped:%';
    if v_status in ('active','default_dirty','nosubdiv','nokey','idle') then
      raise exception 'regrain driver: regrain_step returned % -- the now()-shadow did not take', v_status;
    end if;
    if v_steps > 10000000 then raise exception 'regrain driver: safety limit'; end if;
  end loop;
  raise notice 'regrain driver: % steps, final=%', v_steps, v_status;
end
\$drv\$;
SQL
  ( if [ -n "$BENCH_DSN" ]; then "$PSQL" "$BENCH_DSN" -v ON_ERROR_STOP=1 -f "$RESULTS/regrain_skewed.sql"; else "$PSQL" -v ON_ERROR_STOP=1 -f "$RESULTS/regrain_skewed.sql"; fi ) > "$RESULTS/regrain.log" 2>&1 &
  regrain_pid=$!; BG_PIDS+=("$regrain_pid")
  : > "$RESULTS/regrain.progress.csv"; echo "elapsed_s,coarse,partitions,regrain_copies,rows_copied" >> "$RESULTS/regrain.progress.csv"
  obs0=$(q "select extract(epoch from clock_timestamp())")
  while kill -0 "$regrain_pid" 2>/dev/null; do
    sleep "$BENCH_OBSERVE_INTERVAL"
    poll=$(q "select extract(epoch from clock_timestamp())::bigint
              ||'|'|| coalesce((select coarse_partitions from pgpm.status() where parent='bench.events'::regclass),-1)
              ||'|'|| (select count(*) from pg_inherits where inhparent='bench.events'::regclass)
              ||'|'|| coalesce((select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='regrain_copy'),0)
              ||'|'|| coalesce((select sum(rows) from pgpm.log where parent_table='bench.events'::regclass and action='regrain_copy'),0)" 2>/dev/null) \
      || { echo "  (poll failed, retrying)"; continue; }
    IFS='|' read -r now_s coarse nparts copies copied <<<"$poll"
    el=$(awk -v a="$obs0" -v b="$now_s" 'BEGIN{printf "%.0f", b-a}')
    printf '%s,%s,%s,%s,%s\n' "$el" "$coarse" "$nparts" "$copies" "$copied" >> "$RESULTS/regrain.progress.csv"
    printf '\r  regraining: %ss, coarse=%s, partitions=%s, %s rows copied   ' "$el" "$coarse" "$nparts" "$copied"
    if awk -v e="$el" -v m="$BENCH_DRAIN_MAX_SECS" 'BEGIN{exit !(e+0 > m+0)}'; then
      echo; echo "  regrain hit cap ${BENCH_DRAIN_MAX_SECS}s; stopping the regrain driver"; kill "$regrain_pid" 2>/dev/null || true; break; fi
  done
  echo
  wait "$regrain_pid" 2>/dev/null || echo "  (regrain driver ended: $(tail -1 "$RESULTS/regrain.log" 2>/dev/null))"
  REGRAIN_COARSE_FINAL=$(q "select coalesce((select coarse_partitions from pgpm.status() where parent='bench.events'::regclass),-1)")
  if [ "$REGRAIN_COARSE_FINAL" = "0" ]; then
    echo "  regrain settled -- monolith fully split into '$BENCH_FH_INTERVAL' partitions ($(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='regrain_copy'") microbatches, $(q "select coalesce(sum(rows),0) from pgpm.log where parent_table='bench.events'::regclass and action='regrain_copy'") rows), 0 coarse children"
  else echo "  regrain incomplete (coarse=$REGRAIN_COARSE_FINAL)"; fi
  kill "$regrain_load_pid" 2>/dev/null || true; wait "$regrain_load_pid" 2>/dev/null || true
  printf '%s\n' "$(pctiles regrain)" > "$RESULTS/regrain.pctiles.txt"
  echo "  regrain-phase latency (load on forward partitions): $(cat "$RESULTS/regrain.pctiles.txt")"
fi
convert_end=$(q "select to_char(now(),'YYYY-MM-DD HH24:MI:SS')")

# ---- 5. post (pgpm-partitioned, under load) ----
run_phase post "$BENCH_PHASE_SECS"

# ---- 6. report ----
say "report"
{
  echo "# pg_partition_magician: from_hypertable at-scale load test"
  echo
  echo "- rows: $(q "select count(*) from bench.events")"
  echo "- partitions: $(q "select count(*) from pg_inherits where inhparent='bench.events'::regclass")"
  echo "- timescaledb: $(q "select extversion from pg_extension where extname='timescaledb'") ($(q "show timescaledb.license" 2>/dev/null || echo '?'))"
  echo "- clients: $BENCH_CLIENTS, ops/call: $BENCH_OPS, chunk_interval: $BENCH_CHUNK_INTERVAL, fh_interval: $BENCH_FH_INTERVAL, track_changes: $TRACK"
  echo
  echo "## throughput / latency by phase (client-side, pgbench)"
  echo
  echo "| phase | tps | avg latency | p50 / p95 / p99 / max |"
  echo "|-------|-----|-------------|------------------------|"
  for ph in baseline convert post; do
    if [ "$ph" = convert ]; then s=$(pgbench_log_summary convert); tps=${s%%|*}; lat=${s##*|}
    else tps=$(grep -h 'tps =' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//'); lat=$(grep -h 'latency average' "$RESULTS/$ph.pgbench.txt" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//'); fi
    printf '| %s | %s | %s | %s |\n' "$ph" "${tps:-n/a}" "${lat:-n/a}" "$(cat "$RESULTS/$ph.pctiles.txt" 2>/dev/null || echo n/a)"
  done
  echo
  echo "## conversion (from_hypertable, under load)"
  echo
  echo "- model: **from_hypertable** -- online copy into one plain table, chunk by chunk (source live), with p_track_changes, then a brief-lock cutover (catch-up + delta reconcile + drop hypertable + transmute handoff), then regrain the time-monolith."
  echo "- conversion window: \`$convert_start\` -> \`$convert_end\`"
  echo "- copy: ${copy_secs}s online, copied $DEST_ROWS rows; $DELTA_PENDING in-flight changes (insert/update/delete) captured by the trigger and reconciled at cutover; progress in \`copy.progress.csv\`"
  echo "- cutover: ${cut_secs}s total call (online pre-drain + index pre-build + the brief ACCESS EXCLUSIVE window; see 'cutover lock window' below for the blocking window alone)"
  echo "- **conservation** (immutable cohort users >= $ANCHOR_USER_LO): before=$ANCHOR0 after=$ANCHOR1 -> $([ "$CONS" = ok ] && echo 'CONSERVED ✅' || echo 'MISMATCH ❌')"
  echo "- hypertable catalog rows remaining: $HT_LEFT (0 = torn down)"
  if [ "$BENCH_REGRAIN" = "1" ]; then
    echo "- regrain: $(q "select count(*) from pgpm.log where parent_table='bench.events'::regclass and action='regrain_copy'") copy microbatches, coarse children remaining: \`$REGRAIN_COARSE_FINAL\` (0 = monolith fully split into '$BENCH_FH_INTERVAL' partitions); trace in \`regrain.progress.csv\`"
  fi
  echo
  echo "## cutover lock window (#170)"
  echo
  echo "- mode: $([ "$BENCH_PREDRAIN" = "1" ] && echo '**drained** (p_predrain=>true)' || echo '**undrained** (p_predrain=>false)')"
  echo "- backlog at cutover entry: $DELTA_PENDING delta rows"
  echo "- at-lock residual (delta the under-lock reconcile applied): $AT_LOCK_RESIDUAL"
  echo "- **ACCESS EXCLUSIVE window: ${LOCK_WINDOW_S}s** (whole cutover call: ${cut_secs}s; ± one probe poll)"
  echo "- context: copy ${copy_secs}s, $(q "select count(*) from bench.events") rows / $(q "select pg_size_pretty(coalesce((select sum(pg_total_relation_size(inhrelid)) from pg_inherits where inhparent='bench.events'::regclass), pg_total_relation_size('bench.events'::regclass)))") on disk, drain_batch $BENCH_DRAIN_BATCH"
  echo "- compare with the other arm (run the rung twice, BENCH_PREDRAIN=1 vs 0, on fresh instances): undrained's residual == the whole backlog and its window grows with the copy; drained's residual is bounded by ~drain_batch and its window stays flat."
  if [ "$have_pgfr" = "1" ]; then
    echo "- pgfr corroboration (qualitative, **60s cadence -- cannot resolve the window**, esp. the drained arm): in \`lock_samples\` over \`$convert_start\`..\`$convert_end\`, a sample landing inside a long undrained window shows the workload backends blocked by the cutover's backend on a relation lock -- confirming the timed stall is the ACCESS EXCLUSIVE, not a checkpoint/IO stall."
  fi
  echo
  if [ "$have_pgfr" = "1" ]; then echo "## system metrics (pg_flight_recorder)"; echo; echo "Slice pgfr's series to \`$convert_start\` -> \`$convert_end\`. Narrative: \`pgfr_report.md\`."; fi
} > "$RESULTS/report.md"

if [ "$have_pgfr" = "1" ]; then
  q "select pgfr_analyze.report('$convert_start'::timestamptz,'$convert_end'::timestamptz)" > "$RESULTS/pgfr_report.md" 2>/dev/null || echo "(pgfr report unavailable)" > "$RESULTS/pgfr_report.md"
  q "select pgfr_record.disable()" >/dev/null 2>&1 || true
fi

cat "$RESULTS/report.md"
echo; echo "Full artifacts in $RESULTS/"
