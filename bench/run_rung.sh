#!/usr/bin/env bash
# Climb ONE rung of bench/SIZE_LADDER.md on the provisioned instance.
#
# Resets the database to a clean slate (kills stray local pgbench, terminates server-side
# bench/pgpm backends, unschedules leftover cron, drops pgpm/pgfr/bench), then runs the
# rung's config through bench/run.sh. The conversion runs on green so the run exercises the
# real path (managed PG, pgfr, the NAT'd connection) -- which is where the surprises live.
#
#   bench/run_rung.sh R0|R1|R2|R3 [stress|gentle]
#
# PROFILE (2nd arg, default stress) selects the drain intensity + how we observe:
#   stress -- aggressive drain (2s maintenance, large batch), run-to-completion (observe until the
#             closed tail fully drains). The bug-finder / correctness-and-settle arm.
#   gentle -- representative drain (slow maintenance, small batch sized under work_mem), windowed
#             observation (warm up, then measure the workload over a fixed window without waiting
#             for the drain to finish). The "is the drain unnoticeable?" arm -- it stays under the
#             instance's I/O baseline, so the disk never tires and the measurement is reproducible.
set -euo pipefail

RUNG="${1:?usage: run_rung.sh R0|R1|R2|R3 [stress|gentle]}"
PROFILE="${2:-stress}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck disable=SC1090
source ~/.pgpm-bench.env            # BENCH_DSN (never echoed) + project metadata
set +a
: "${BENCH_DSN:?BENCH_DSN must come from ~/.pgpm-bench.env}"

# ---- shared knobs (same workload + pgfr across rungs and profiles) ----
export BENCH_MONTHS=2 BENCH_GEN_JOBS=8 BENCH_CHUNK=2000000
export BENCH_CLIENTS=16 BENCH_JOBS=8 BENCH_OPS=10
export BENCH_OBSERVE_INTERVAL=10
export BENCH_PREPARE_ADOPT=1 BENCH_PGFR=1

# ---- per-rung scale (see bench/SIZE_LADDER.md) ----
case "$RUNG" in
  R0) export BENCH_ROWS=1000000  BENCH_PHASE_SECS=45 BENCH_DRAIN_BATCH=100000 BENCH_DRAIN_IDLE_SECS=45 BENCH_DRAIN_MAX_SECS=600 ;;
  R1) export BENCH_ROWS=3000000  BENCH_PHASE_SECS=45 BENCH_DRAIN_BATCH=100000 BENCH_DRAIN_IDLE_SECS=45 BENCH_DRAIN_MAX_SECS=600 ;;
  R2) export BENCH_ROWS=10000000 BENCH_PHASE_SECS=60 BENCH_DRAIN_BATCH=100000 BENCH_DRAIN_IDLE_SECS=60 BENCH_DRAIN_MAX_SECS=1200 ;;
  R3) export BENCH_ROWS=40000000 BENCH_PHASE_SECS=90 BENCH_DRAIN_BATCH=150000 BENCH_DRAIN_IDLE_SECS=90 BENCH_DRAIN_MAX_SECS=2700 ;;
  *)  echo "unknown rung '$RUNG' (want R0|R1|R2|R3)"; exit 2 ;;
esac

# ---- per-profile drain intensity + observe mode (overrides the rung's stress defaults) ----
case "$PROFILE" in
  stress) export BENCH_MAINT_INTERVAL='2 seconds' BENCH_OBSERVE_MODE=settle ;;
  gentle) # small batch (fits work_mem -> no temp spill), slow cron (stays under I/O baseline),
          # windowed observe (warm up, then measure -- don't wait for the drain to finish).
          export BENCH_MAINT_INTERVAL='20 seconds' BENCH_OBSERVE_MODE=window \
                 BENCH_DRAIN_BATCH=20000 BENCH_CONVERT_WARMUP_SECS=60 \
                 BENCH_CONVERT_WINDOW_SECS=300 BENCH_DRAIN_MAX_SECS=900 ;;
  *)      echo "unknown profile '$PROFILE' (want stress|gentle)"; exit 2 ;;
esac

export RESULTS="${RESULTS:-$DIR/results/$RUNG-$PROFILE}"

printf '\n==== run_rung %s [%s] : %s rows, %s months ====\n' "$RUNG" "$PROFILE" "$BENCH_ROWS" "$BENCH_MONTHS"

# ---- reset to a clean slate (idempotent) ----
pkill -f 'bench/workload.pgbench' 2>/dev/null || true   # any orphaned local pgbench
PSQL=(psql "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAq -c "set statement_timeout=0")
"${PSQL[@]}" -c "select count(pg_terminate_backend(pid)) from pg_stat_activity
  where datname=current_database() and pid<>pg_backend_pid()
    and (query ilike '%bench.%' or query ilike '%pgpm%' or query ilike '%generate_events%'
         or application_name ilike '%pgbench%')" >/dev/null || true
sleep 2
"${PSQL[@]}" -c "select count(cron.unschedule(jobid)) from cron.job
  where jobname like 'pgfr%' or jobname like 'pgpm%' or jobname like '%bench%'" >/dev/null || true
psql "$BENCH_DSN" -tAq -c "set statement_timeout=0" \
  -c "drop extension if exists pgfr_analyze cascade; drop extension if exists pgfr_record cascade;
      drop schema if exists pgfr_analyze cascade; drop schema if exists pgfr_record cascade;
      drop schema if exists bench cascade; drop schema if exists pgpm cascade" >/dev/null 2>&1 || true

mkdir -p "$RESULTS"; rm -f "$RESULTS"/* 2>/dev/null || true
exec "$DIR/run.sh"
