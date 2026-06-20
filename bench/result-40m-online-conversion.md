# Banked result: 40M-row online conversion under load (rung 3)

A run of the passive-observer harness (`bench/run.sh`) converting an unpartitioned
`bench.events` to RANGE-partitioned **online**, while a 16-client OLTP workload runs
continuously, on a provisioned Supabase **2xlarge** (8 vCPU / 32 GB RAM, gp3 500 GB /
12 000 IOPS, PostgreSQL 17.6, staging "green"). This is rung 3 of the size ladder
(`bench/SIZE_LADDER.md`); it is the rung that first passed end to end.

## Setup
- **40 M rows**, spread over the last 2 months (~Apr 20 → Jun 20) → ~12 GB heap+indexes
  unpartitioned. Generated server-side by 8 parallel sessions.
- Conversion: `build_pk_concurrently` (online PK) → `adopt(p_paused => false)` →
  `pgpm.maintenance` scheduled on pg_cron every 2 s. pgpm self-drives premake + drain;
  the harness only observes. Drain batch 150 000.

## Result: converted online, workload never stopped
- **Online PK build: 51.8 s** (`CREATE INDEX CONCURRENTLY` via a pg_cron worker).
- **`adopt()`: 8.3 s metadata cutover**, reused the pre-built index (no in-txn rebuild).
- **Drain: 27.4 M closed-tail rows moved** in 184 microbatches, attaching 2 closed
  partitions; default drained to the open-month residue (`closed_rows = 0`). 6 partitions
  total (default + 3 premade-ahead + 2 drained). **40 M rows conserved.**
- **`maintenance()` hardening validated under load:** premake **succeeded 3×** (during
  lulls) and **deferred 14×** (`premake_skip`, when it lost the lock race to the live
  insert workload), and the drain ran to completion regardless. Before the fix, the first
  premake deadlock aborted the whole maintenance run and the drain never started.

## Throughput / latency by phase
| phase | tps | avg latency | server-side p50 / p95 / p99 / max |
|-------|-----|-------------|-----------------------------------|
| baseline (unpartitioned) | 140.7 | 113.7 ms | 108 / 160 / 178 / 316 ms |
| convert (under conversion) | 9.9 | 182.5 ms | 104 / 177 / 281 / 13 415 ms |
| post (partitioned) | 165.8 | 96.4 ms | 95 / 105 / 162 / 318 ms |

Throughput dropped sharply during the convert phase (the drain's delete+insert microbatches
emit **123 GB of WAL**, see below, and contend for I/O), but the workload kept committing
(0 failed) and p50 held ~104 ms; post-conversion latency is *better* than baseline (queries
now hit the right partition). The 13.4 s max during convert is lock-contention tail from the
partition attaches.

## Health by phase
| phase | events size | partitions | bench dead tup | active backends |
|-------|-------------|------------|----------------|-----------------|
| baseline | 12 GB | 0 | 714 | 2 |
| convert | 21 GB | 6 | 7 406 | 1 |
| post | 21 GB | 6 | 5 404 | 1 |

## WAL / checkpoint by phase (deltas)
| phase | WAL bytes | WAL records | WAL FPI | checkpoints | ckpt buffers |
|-------|-----------|-------------|---------|-------------|--------------|
| baseline | 2.7 GB | 317 052 | 32 218 | 1 | 206 141 |
| convert | **123.4 GB** | 146 937 322 | 21 599 550 | 34 | 9 046 810 |
| post | 205.3 MB | 335 167 | 39 253 | 1 | 1 025 |

The drain is heavily WAL-amplified (delete + re-insert of every closed-tail row, plus FPIs
after each of the 34 checkpoints it forced). This is the dominant cost of the online drain
and the thing that scales painfully (see the ladder's disk-bound rungs).

## Wall-clock & a known harness issue
Total run ~58 min (05:43 → 06:41). Of that, the **server-side drain itself was ~30 min**;
generation ~6 min; phases ~3 min. The remainder is a harness artifact: the observer's
progress sampling had a **single ~46-min-equivalent gap** (`drain.progress.csv` jumps from
observed_s 90 → 2851) where one poll iteration blocked, so the observer did not register
"drain settled" until ~17 min after the drain had actually finished. The **server-side
drain was unaffected** (it runs on pg_cron, not on the observer's connection); this is the
passive-observer design working, but the observer's *visibility* stalled. Root cause of the
poll stall is not yet established from the evidence; candidate fix: give each observer poll a
bounded `statement_timeout` + reuse one persistent connection rather than one psql per poll.

## Bugs this rung's path surfaced (all fixed before this pass)
1. Observer falsely declared "settled" before the drain started (`coalesce(age, 999999)`).
2. `maintenance()` let a premake deadlock abort the drain (the hardening above).
3. Convert-phase pgbench was orphaned (harness killed the subshell wrapper, not pgbench).
4. No TCP keepalives → the bulk-generation connections went half-open over the NAT'd path
   and the harness hung. Keepalives now added to every connection.
