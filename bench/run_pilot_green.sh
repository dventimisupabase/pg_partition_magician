#!/usr/bin/env bash
# Pilot run of the pure-observer harness against the provisioned green 2xlarge.
# Small scale on purpose: validate the full pipeline end-to-end (install, pg_cron,
# online PK build, online adopt, pgpm self-driven drain, settle detection, pgfr,
# WAL/checkpoint gauges, report) before any at-scale run. NOT committed.
set -euo pipefail

set -a
# shellcheck disable=SC1090
source ~/.pgpm-bench.env          # sets BENCH_DSN (never echoed) + project metadata
set +a

# ---- FAST pilot scale -------------------------------------------------------
# A pilot exists to validate the PIPELINE quickly, not to test at scale. Keep the
# closed tail tiny so the whole run is ~5 min and we can iterate fast and often:
# 3M rows over 2 months -> ~1.5M-row closed tail -> ~1-2 min drain. Concurrency
# (16 clients) is kept high so adopt/premake/drain still run under real contention.
# (For an at-scale confirmation run, bump BENCH_ROWS to 40M+ and the caps below.)
export BENCH_ROWS=3000000         # ~1 GB; ~1.5M rows in the closed tail to drain
export BENCH_MONTHS=2             # current (open) + prior (closed)
export BENCH_GEN_JOBS=8           # 8 vCPU -> 3M generates in well under a minute
export BENCH_CHUNK=1000000

# ---- ambient workload ----
export BENCH_CLIENTS=16
export BENCH_JOBS=8
export BENCH_OPS=10               # cached -> a few ms/txn, safely under statement_timeout
export BENCH_PHASE_SECS=45        # baseline / post (short -- enough for stable tps)

# ---- conversion (pgpm self-drives; harness only observes) ----
export BENCH_PREPARE_ADOPT=1      # build the composite PK index CONCURRENTLY before adopt
export BENCH_DRAIN_BATCH=100000   # rows per drain_step (~15 batches for the tail)
export BENCH_MAINT_INTERVAL='2 seconds'   # pg_cron tick for pgpm.maintenance
export BENCH_OBSERVE_INTERVAL=10
export BENCH_DRAIN_IDLE_SECS=45   # "settled" after 45s with no drain activity (and >=1 drain op)
export BENCH_DRAIN_MAX_SECS=600   # 10-min safety cap (tail is ~1.5M rows)

# ---- observability ----
export BENCH_PGFR=1               # wire in pg_flight_recorder (fresh install)

exec "$(dirname "${BASH_SOURCE[0]}")/run.sh"
