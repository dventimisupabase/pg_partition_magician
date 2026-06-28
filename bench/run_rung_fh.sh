#!/usr/bin/env bash
# Climb ONE rung of the from_hypertable ladder (bench/SIZE_LADDER.md scales) on a green PG15 instance.
#
# Sibling of bench/run_rung.sh: where that converts a plain id-table with transmute+refine, THIS converts
# a TimescaleDB hypertable via from_hypertable (online copy -> brief cutover -> refine the time-monolith)
# under load, on PostgreSQL 15 with Apache TimescaleDB. Each rung runs on its OWN fresh PG15 2XL green
# instance (see bench-fresh-instance-per-run): one provisioned project per rung, top to bottom.
#
#   bench/run_rung_fh.sh R0|R1|R2|R3|R4|R5
#
# Connection: the rung's dedicated instance is identified by BENCH_PROJECT_REF + BENCH_DB_PASSWORD +
# BENCH_REGION (exported by the caller / a per-rung env file). We always route through the green Supavisor
# SESSION-mode pooler (port 5432): from_hypertable COMMITs and needs per-connection statement_timeout=0 and
# advisory locks, which transaction mode (6543) would break. The DSN is built at runtime and never echoed.
set -euo pipefail

RUNG="${1:?usage: run_rung_fh.sh R0|R1|R2|R3|R4|R5}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- connection (green session pooler, built from the rung's instance metadata) ----
: "${BENCH_PROJECT_REF:?BENCH_PROJECT_REF must be set (the dedicated green project for this rung)}"
: "${BENCH_DB_PASSWORD:?BENCH_DB_PASSWORD must be set}"
: "${BENCH_REGION:?BENCH_REGION must be set (e.g. us-east-1)}"
pooler_host="${BENCH_POOLER_HOST:-aws-0-${BENCH_REGION}.pooler.supabase.green}"
pw_enc="$(python3 -c 'import urllib.parse,os;print(urllib.parse.quote(os.environ["BENCH_DB_PASSWORD"],safe=""))')"
export BENCH_DSN="postgresql://postgres.${BENCH_PROJECT_REF}:${pw_enc}@${pooler_host}:5432/postgres?sslmode=require"
echo "  connection: green session-mode pooler ($pooler_host:5432), project ${BENCH_PROJECT_REF}"

# ---- shared knobs (hold compute + workload constant across the ladder; vary only scale) ----
export BENCH_GEN_JOBS="${BENCH_GEN_JOBS:-8}"      # 2XL = 8 vCPU
export BENCH_CLIENTS="${BENCH_CLIENTS:-16}" BENCH_JOBS="${BENCH_JOBS:-8}" BENCH_OPS="${BENCH_OPS:-10}"
export BENCH_OBSERVE_INTERVAL="${BENCH_OBSERVE_INTERVAL:-10}"
export BENCH_FH_INTERVAL="${BENCH_FH_INTERVAL:-1 month}"   # pgpm partition width + refine target
export BENCH_TRACK_CHANGES="${BENCH_TRACK_CHANGES:-1}"     # full-online: reconcile in-flight upd/del at cutover
export BENCH_REFINE="${BENCH_REFINE:-1}"
export BENCH_OBTAIN="${BENCH_OBTAIN:-4}"
export BENCH_PREDRAIN="${BENCH_PREDRAIN:-1}"               # #170 A/B: 1 = online pre-drain (drained), 0 = undrained
export BENCH_LOCKPROBE="${BENCH_LOCKPROBE:-1}"             # time the cutover's true ACCESS EXCLUSIVE window
export BENCH_PGFR="${BENCH_PGFR:-1}"
export BENCH_PGFR_DIR="${BENCH_PGFR_DIR:-$DIR/vendor/pg_flight_recorder}"

# ---- per-rung scale (BENCH_ROWS mirrors SIZE_LADDER.md; CHUNK_INTERVAL keeps #chunks ~25-200) ----
# BENCH_CHUNK = generator commit chunk; BENCH_CHUNK_INTERVAL = hypertable chunk width (copy iterates these).
case "$RUNG" in
  R0) export BENCH_ROWS=1000000   BENCH_MONTHS=6  BENCH_CHUNK=1000000 BENCH_CHUNK_INTERVAL='1 week' BENCH_PHASE_SECS=30 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-50000}  BENCH_DRAIN_MAX_SECS=1200 ;;
  R1) export BENCH_ROWS=3000000   BENCH_MONTHS=6  BENCH_CHUNK=1500000 BENCH_CHUNK_INTERVAL='1 week' BENCH_PHASE_SECS=30 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-50000}  BENCH_DRAIN_MAX_SECS=1200 ;;
  R2) export BENCH_ROWS=10000000  BENCH_MONTHS=6  BENCH_CHUNK=2000000 BENCH_CHUNK_INTERVAL='3 days' BENCH_PHASE_SECS=45 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-100000} BENCH_DRAIN_MAX_SECS=1800 ;;
  R3) export BENCH_ROWS=40000000  BENCH_MONTHS=6  BENCH_CHUNK=2000000 BENCH_CHUNK_INTERVAL='1 day'  BENCH_PHASE_SECS=60 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-150000} BENCH_DRAIN_MAX_SECS=3600 ;;
  R4) export BENCH_ROWS=120000000 BENCH_MONTHS=12 BENCH_CHUNK=2000000 BENCH_CHUNK_INTERVAL='1 day'  BENCH_PHASE_SECS=90 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-250000} BENCH_DRAIN_MAX_SECS=36000 ;;
  R5) export BENCH_ROWS=350000000 BENCH_MONTHS=12 BENCH_CHUNK=2000000 BENCH_CHUNK_INTERVAL='12 hours' BENCH_PHASE_SECS=90 BENCH_DRAIN_BATCH=${BENCH_DRAIN_BATCH:-500000} BENCH_DRAIN_MAX_SECS=90000 ;;
  *)  echo "unknown rung '$RUNG' (want R0|R1|R2|R3|R4|R5)"; exit 2 ;;
esac

export RESULTS="${RESULTS:-$DIR/results/fh-$RUNG}"

printf '\n==== run_rung_fh %s : %s rows, %s months, chunk=%s, fh_interval=%s ====\n' \
  "$RUNG" "$BENCH_ROWS" "$BENCH_MONTHS" "$BENCH_CHUNK_INTERVAL" "$BENCH_FH_INTERVAL"

# ---- reset to a clean slate (idempotent; cheap on a fresh instance, safety on a reused one) ----
# Kill only THIS run's leftover pgbench, matched by the project ref (which is in the DSN on the pgbench
# command line), not every workload_fh.pgbench on the machine -- otherwise running rungs/arms in parallel
# (one fresh project each) would clobber each other's workloads at reset time (issue #177). The server-side
# RESET_KILL below is already scoped to this project's database via current_database().
pkill -f "${BENCH_PROJECT_REF}.*workload_fh.pgbench" 2>/dev/null || true
RESET_KILL="select count(pg_terminate_backend(pid)) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and (query ilike '%bench.%' or query ilike '%pgpm%' or query ilike '%generate_events%' or application_name ilike '%pgbench%')"
RESET_CRON="select count(cron.unschedule(jobid)) from cron.job where jobname like 'pgfr%' or jobname like 'pgpm%' or jobname like '%bench%'"
RESET_DROP="drop extension if exists pgfr_analyze cascade; drop extension if exists pgfr_record cascade; drop schema if exists pgfr_analyze cascade; drop schema if exists pgfr_record cascade; drop schema if exists bench cascade; drop schema if exists pgpm cascade"
psql "$BENCH_DSN" -v ON_ERROR_STOP=1 -tAq -c "set statement_timeout=0" -c "$RESET_KILL" >/dev/null 2>&1 || true
sleep 2
psql "$BENCH_DSN" -tAq -c "set statement_timeout=0" -c "$RESET_CRON" >/dev/null 2>&1 || true
psql "$BENCH_DSN" -tAq -c "set statement_timeout=0" -c "$RESET_DROP" >/dev/null 2>&1 || true

mkdir -p "$RESULTS"; rm -f "$RESULTS"/* 2>/dev/null || true
exec "$DIR/run_fh.sh"
