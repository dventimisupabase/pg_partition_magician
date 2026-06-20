# Banked result: 40M-row online conversion, **gentle/steady-state arm** (rung 3)

The **gentle** profile (`bench/run_rung.sh R3 gentle`) of the load-test harness converting an
unpartitioned `bench.events` to RANGE-partitioned **online**, while a 16-client OLTP workload runs
continuously, on a provisioned Supabase **2xlarge** (8 vCPU / 32 GB RAM, gp3 500 GB / 12 000 IOPS,
PostgreSQL 17.6, staging "green"). Same engine and same 40M-row workload as the
[stress result](result-40m-online-conversion.md); the question is different.

- **Stress arm** asks *"converted online + fully drained, and what breaks when we over-drive it?"*
  It runs the drain hard (2 s cron, 150k batches) to completion. That manufactures I/O stress
  (123 GB WAL, 34 forced checkpoints, tps → 9.9), a bug-finder, **not** how pgpm is meant to run.
- **Gentle arm** (this doc) asks *"is the drain unnoticeable to the workload?"* It drives pgpm at
  its **intended** pace (20 s cron, 20k batches sized to fit `work_mem`) and **measures a fixed
  window** of steady-state draining rather than waiting for the drain to finish (a gentle drain of
  a large table runs for hours/days in the background by design; it needn't complete in a benchmark).

## Setup
- **39.9 M rows**, ~2 months of history → ~12 GB heap+indexes unpartitioned. Generated server-side
  by 8 parallel sessions, then **`VACUUM (FREEZE, ANALYZE)`** so the post-bulk-load freeze WAL
  settles *before* measurement (`BENCH_PREFREEZE=1`; see "I/O attribution").
- Conversion: `build_pk_concurrently` (online PK) → `adopt()` → `pgpm.maintenance` on pg_cron
  **every 20 s**, **drain batch 20 000**. pgpm self-drives premake + drain; the harness observes.
- Observe mode: **window**, 60 s warm-up to steady-state draining, then a 300 s measurement window.
  Convert metrics are restricted to that window (the one-time adopt cutover is excluded).
- **Connection path: Supavisor session-mode pooler (port 5432), `BENCH_USE_POOLER=1`**, over the
  direct `.red`/Tailscale path the workload connection dropped mid-window on every at-scale run, so
  the long window could never be captured. The public pooler path holds it (see "Connection path").

## Result: the gentle drain is unnoticeable to the workload, at scale
The 300 s steady-state window was **captured in full (n = 36 100 transactions)** and the workload
latency **tracks baseline at every percentile** while pgpm drains the closed tail underneath it:

| phase | tps | client p50 / p95 / p99 (pgbench --log) |
|-------|-----|----------------------------------------|
| baseline (unpartitioned) | 139.3 | 76.42 / 83.68 / 177.99 ms |
| **convert (steady-state drain)** | 177 | **76.66 / 83.47 / 168.76 ms** |
| post (partitioned) | 199.2 | 77.07 / 83.64 / 177.66 ms |

**The verdict is the latency comparison, and it is unambiguous: the drain did not slow the
workload.** Convert p50/p95 are statistically identical to baseline and p99 is *better*. During
the window pgpm self-drove correctly under live load: **23 drain microbatches** (460k closed-tail
rows moved), premake **succeeded 3× and deferred 6×** under lock contention (the back-off ceding to
the live insert workload, exactly as intended). Closed tail intentionally left draining
(26.6 M rows remain, a windowed run is not run to completion).

- `build_pk_concurrently`: online PK index built in **322.9 s** (no table lock; workload unaffected).
  Slow here because the instance's EBS burst was depleted from a day of runs, an environment
  confound that lengthens the *one-time* index build but does not touch the drain-window verdict.
- `adopt()`: **1.5 s metadata cutover** (reused the pre-built index; no in-txn rebuild).

This corroborates a clean R0 over the same path (convert p50 75.82 ms = baseline 75.80 ms,
n = 28 805) and an earlier R3 over the flaky path whose window survived long enough to aggregate
(convert p50 91.3 / p95 146.5 / p99 186.4, all ≤ baseline).

## I/O attribution: the drain is not the I/O stressor
pgfr (server-side, continuous) over the window flagged 2 forced checkpoints, a checkpoint, and
1.05 GB temp. **None is the drain**, established three ways:

1. **Temp spill is the one-time PK index build.** `convert.temp.csv` attributes all 1.05 GB to a
   single statement, `create unique index concurrently … events_pgpm_pkey_pre (created_at, id)`
   (`build_pk_concurrently` sorting ~40M rows during adopt **prep**). The drain's 20k-row batches
   fit in `work_mem` and spill nothing. (Identical attribution on the `.red` run, reproducible.)
2. **Forced checkpoints are rate-independent → not the drain.** Gentle R0 uses the *identical* drain
   rate and produces **zero** forced checkpoints; only the large rung does. A symptom that scales
   with table size but not drain rate is the *load*, not the drain. The residual 2 checkpoints are
   the CIC's own index WAL; the window moved ~460k rows (~0.7 GB WAL).
3. **Pre-freeze cut the load aftermath out of the window.** Settling the bulk-load freeze WAL before
   measuring dropped forced checkpoints **6 → 2** and checkpoint **sync_time 24.6 s → 0.17 s**
   between two otherwise-identical R3 runs, direct proof the bulk of the I/O the *unfrozen* run
   blamed on the window was the load's freeze, not the conversion.

What remains (one-time CIC index build) is the inherent price of going online, building the PK
without an exclusive lock, and it happens **once**, before the table is partitioned. The
steady-state drain itself stays under the instance's I/O baseline, which is the design goal.

## Connection path: Tailscale was the measurement blocker, not pgpm or the disk
Over the direct `.red` endpoint (Postgres over a Tailscale/NAT CGNAT route) the **workload
connection dropped ~80 s into convert on all 3 runs**, truncating the window (n=8662 or n/a). The
server was unaffected every time, pgpm kept draining straight through the client blackout
(`drain_ops` climbing, premake creating partitions). Switching the client to the **Supavisor
session-mode pooler** (public path) resolved it: the window is captured in full and latency is
*lower* (~76 ms vs ~90 ms on Tailscale). Session mode (not transaction mode 6543) is required, the
harness needs a stable server backend per connection for `set statement_timeout=0`, the COMMIT-ing
generator procedure, and pgpm's advisory locks. The session-mode client cap had to be raised
(`default_pool_size` 25 → 60 via the Management API) to fit 16-client pgbench across all phases plus
the observer. The earlier "instance burst-starvation" hypothesis is **refuted**: same instance,
same burst state, different network path, and the window holds.
