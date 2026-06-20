# At-scale load test

Proves `pg_partition_magician` converts a **giant, live, query-loaded** table to
partitioned **online**, and measures latency / throughput / health *before*,
*during*, and *after* the conversion.

## What it builds

A small multi-table OLTP schema (`bench`) with one deliberately huge table:

| table | role |
|-------|------|
| `bench.events` | the partition candidate: append-heavy, target **>100 GB** |
| `bench.users` | 50k-row dimension the workload joins/filters against |
| `bench.user_seen` | small companion the workload also writes |

`bench.events` rows carry a ~360-byte incompressible payload, so the heap reaches
the target size at a predictable row count (~400 B/row ⇒ ~300M rows ≈ 120 GB).

## Where the data comes from: generated **server-side**

The bulk data is generated **inside the database** by `bench.generate_events(...)`,
not pushed from the client. A 100 GB+ table moved over a client connection would
make the network the bottleneck (hours of wire transfer) and prove nothing about
Postgres. Server-side generation runs at the server's I/O speed, commits per
chunk (bounded WAL/memory, restartable), and nothing crosses the wire.

The client (`pgbench`) is used only for the **load phases**, where each request is
tiny. To keep the *server* the bottleneck there too (not the WAN, when the driver
isn't co-located), each `pgbench` transaction calls `bench.workload_step(ops)`,
which runs many index-supported ops in one round-trip. Server-side latency is read
WAN-free from `pg_stat_statements` and from the `pgbench --log` percentiles.

A single `INSERT…SELECT` is single-core-bound, so generating hundreds of millions
of rows on one session is slow regardless of instance size. Set `BENCH_GEN_JOBS` to
about the vCPU count to split the target across that many concurrent generator
sessions (they all append to `bench.events`; the identity sequence keeps ids unique
and the month-spread is unchanged).

## The phases (a passive observer)

pgpm is **self-driving**: you call `adopt()` once and pgpm's own pg_cron maintenance
premakes and drains the default autonomously, inside the database. So this harness does
**not** perform the partitioning: it sets pgpm up the way an operator would, drives an
ambient workload, and *observes*. Three phases:

1. **baseline**: ambient workload against the *unpartitioned* table.
2. **convert**: fire `pgpm.adopt()` once (`p_paused => false`) and schedule
   `pgpm.maintenance` on pg_cron, then **pgpm** premakes and drains the default on its
   own while the harness drives the workload and watches `pgpm.log` until the drain settles.
   The harness never calls `drain_step`; because the conversion runs server-side, a
   dropped harness connection can't stop it.
3. **post**: ambient workload against the now-partitioned table.

The report compares client tps + p50/p95/p99 latency across the three phases and summarizes
pgpm's own conversion (drain/premake from `pgpm.log`). The system-metric time-series (WAL,
checkpoints, `pg_stat_io`, wait/lock events) is **pg_flight_recorder's** job: it records them
continuously and server-side, and the report slices its series to the conversion window. So
degradation *while pgpm converts the table under load* is visible without the harness
hand-rolling gauges.

## Running it

Point it at a database via `BENCH_DSN` (or the standard `PG*` env vars). The DSN
is passed positionally to `psql`/`pgbench` and is **never echoed or logged**.

```bash
# small local smoke test (Docker Postgres with pg_cron), ~1.5 GB
BENCH_DSN='postgres://postgres:postgres@localhost:5515/postgres' \
  BENCH_ROWS=4000000 BENCH_MONTHS=6 BENCH_PHASE_SECS=20 \
  BENCH_CLIENTS=8 BENCH_DRAIN_BATCH=20000 \
  bench/run.sh

# at scale, against a provisioned large instance (e.g. 2XL: 8 vCPU), with pg_flight_recorder
BENCH_DSN='postgres://...:...@db.<ref>.supabase.co:5432/postgres' \
  BENCH_ROWS=300000000 BENCH_MONTHS=12 BENCH_PHASE_SECS=180 \
  BENCH_GEN_JOBS=8 BENCH_CLIENTS=16 BENCH_JOBS=8 BENCH_DRAIN_BATCH=50000 \
  BENCH_PGFR=1 BENCH_PGFR_DIR=bench/vendor/pg_flight_recorder \
  bench/run.sh
```

Run the driver **as close to the database as possible** (same region / a VM in the
same network). The server-side workload design tolerates latency, but co-location
keeps `pgbench`'s own tps/latency numbers meaningful alongside the server-side ones.

Pick a scale from **[`SIZE_LADDER.md`](SIZE_LADDER.md)** and climb it rung by rung: a
larger run is only worth doing once the one below it has passed cleanly.

## Knobs

| env | default | meaning |
|-----|---------|---------|
| `BENCH_DSN` | *(PG\* env)* | libpq conninfo / URI (never logged) |
| `BENCH_ROWS` | `300000000` | target rows in `bench.events` |
| `BENCH_MONTHS` | `12` | months of history to spread across |
| `BENCH_CHUNK` | `2000000` | generator commit chunk |
| `BENCH_GEN_JOBS` | `1` | parallel generator sessions: set to ≈vCPU to fan generation across cores (one `INSERT…SELECT` is single-core-bound) |
| `BENCH_DEFER_INDEX` | `0` | drop the secondary index during bulk load, rebuild after; avoids scattered per-row index maintenance across hundreds of millions of inserts |
| `BENCH_PREPARE_ADOPT` | `0` | run `pgpm.build_pk_concurrently()` (online PK index, cron-driven inside pgpm) before `adopt`, so the cutover is metadata-only. **Essential at scale**: otherwise `adopt` builds the index in-transaction under `ACCESS EXCLUSIVE` (a multi-minute write-blocking window on a 100GB+ table) |
| `BENCH_INTERVAL` | `1 month` | partition width |
| `BENCH_PREMAKE` | `3` | future partitions pgpm premakes (configured on adopt; pgpm's maintenance does it) |
| `BENCH_CLIENTS` / `BENCH_JOBS` | `16` / `4` | ambient-workload pgbench concurrency |
| `BENCH_OPS` | `50` | server-side ops per `workload_step` call, **calibrate to scale**: each op is disk-bound (~hundreds of ms) once the table exceeds RAM, so a value tuned on a cached table blows `statement_timeout` at scale. Keep it small (e.g. 5–10) for >RAM tables |
| `BENCH_PHASE_SECS` | `120` | baseline/post observation duration |
| `BENCH_MAX_FAIL_PCT` | `5` | abort right after baseline if more than this % of transactions failed (catches a mis-calibrated `BENCH_OPS` in minutes instead of hours) |
| `BENCH_DRAIN_BATCH` | `20000` | rows per `drain_step`, set on `adopt`; **pgpm** uses it when *it* drains |
| `BENCH_MAINT_INTERVAL` | `5 seconds` | pg_cron schedule for `pgpm.maintenance`, how often pgpm drives premake + drain |
| `BENCH_OBSERVE_INTERVAL` | `15` | how often (s) the harness samples while pgpm drains |
| `BENCH_DRAIN_IDLE_SECS` | `120` | drain is "settled" after this long with no pgpm drain activity in `pgpm.log` |
| `BENCH_DRAIN_MAX_SECS` | `3600` | safety cap on the observation window |
| `BENCH_OBSERVE_MODE` | `settle` | `settle` = observe until the drain fully completes; `window` = warm up then measure a fixed window without waiting for completion (see Profiles) |
| `BENCH_CONVERT_WARMUP_SECS` | `30` | window mode: let the drain reach steady state before measuring |
| `BENCH_CONVERT_WINDOW_SECS` | `300` | window mode: measure the workload for this long, then stop (drain left running) |
| `BENCH_PGFR` / `BENCH_PGFR_DIR` | `0` / `bench/vendor/pg_flight_recorder` | install + enable pg_flight_recorder (record + analyze) for WAL/checkpoint/wait telemetry; clone the repo into `BENCH_PGFR_DIR` first |
| `BENCH_SKIP_GENERATE` | `0` | reuse already-loaded data |

## Profiles (one engine, different questions)

A single benchmark can't be everything at once, *aggressive* (to find limits and bugs) and
*gentle* (to show the conversion is unnoticeable) and *complete-in-a-window* and *at-scale* are
contradictory demands. So `bench/run_rung.sh <rung> [profile]` runs the same engine under named
profiles that bundle drive-intensity + how we observe:

- **`stress`** (default), aggressive drain (2 s maintenance, large batch), **run to completion**
  (`BENCH_OBSERVE_MODE=settle`): drive the drain hard so it finishes within the run, then confirm
  it settled. This is the *stress test*, it deliberately exceeds production load to surface
  bugs and limits, and it's how most of pgpm's drain/premake hardening was found.
- **`gentle`**, representative drain (20 s maintenance, small batch sized **under `work_mem`** so
  it never spills temp), **windowed** (`BENCH_OBSERVE_MODE=window`): warm up until the drain is
  steadily running, then measure the workload over a fixed window and compare it to baseline, 
  *without* waiting for completion (a gentle drain of a large table takes hours/days and doesn't
  need to finish to answer "is it unnoticeable?"). Kept under the instance's I/O baseline, so the
  EBS burst never depletes and the measurement is reproducible.

The two are complementary, not competing: throttling needs no pgpm change (it's just `drain_batch`
+ the maintenance cadence, pgpm's intended gentle mode), and the stress arm earns its keep as a
bug-finder. Profiles compose with the size ladder as a *rung × profile* matrix; results land in
`results/<rung>-<profile>/`.

## Faster reruns

The expensive setup is **generation** (~minutes/10s-of-GB, CPU-bound on `md5()`) and the
**online PK index build** (`prepare` phase, ~tens of minutes on a 100GB+ table). Two ways
to cut that on repeat runs, with an honest caveat on each:

- **Scale the instance up for setup, down to measure (the bigger lever).** Generation and
  the index build are CPU/IO/`maintenance_work_mem`-bound, so a larger compute tier builds
  both far faster, and they're *setup*, not the measurement, so speeding them up doesn't
  affect the >RAM realism. The drain (the long pole) is the measurement and must stay on the
  target tier. Compute resize is a **restart**, so this can't happen mid-run: do it as
  *scale up → generate + `build_pk_concurrently` → scale down (restart) → `BENCH_SKIP_GENERATE=1`
  measurement run*. The measurement run's `adopt` reuses the already-built index automatically.

- **Reuse the generated data (`BENCH_SKIP_GENERATE=1`).** Keep an untouched seed copy of the
  rows so you don't pay `md5()` generation again:

  ```sql
  -- once, after the first generation (before adopt):
  create table bench.events_seed as select * from bench.events;
  -- before each rerun (adopt is destructive, it partitions bench.events):
  drop table if exists bench.events cascade;
  create table bench.events (like bench.events_seed including defaults);
  alter table bench.events add column id bigint generated by default as identity primary key;
  insert into bench.events (created_at, user_id, kind, payload)
    select created_at, user_id, kind, payload from bench.events_seed;
  ```

  **Caveat:** this banks only the *data*; a copy is faster than regeneration (no `md5()`),
  but the PK index build is per-conversion and can't be reused (`adopt` consumes it), and the
  seed doubles disk. So it saves the generation time, not the index-build time. The scale-up
  approach above is what speeds the index build.

## Output (`bench/results/`)

- `report.md`: the before/during/after comparison, client tps + latency percentiles per
  phase, a summary of pgpm's own conversion (drain/premake counts, rows moved, closed-tail
  remaining, from `pgpm.log`), and a pointer to the pgfr system-metric series sliced to the
  conversion window.
- `<phase>.pgbench.txt`: raw pgbench summary (tps, latency average).
- `<phase>.pctiles.txt`: client p50/p95/p99/max from the per-transaction log.
- `<phase>.pgss.csv`: top server-side workload statements per phase (a scoped
  `pg_stat_statements` reset/dump, WAN-free timing for the workload itself).
- `drain.progress.csv`: the default-partition drain curve under load (observed_s,
  default_rows, partitions, drain_ops), pgpm's own conversion progress.
- **pg_flight_recorder** (when `BENCH_PGFR=1`): `pgfr_report.md`, the `pgfr_analyze`
  narrative for the conversion window (anomalies, wait-event summary, WAL/checkpoint/IO
  snapshots over time).

> `bench/results/` is git-ignored except for committed example reports.

### System metrics are pg_flight_recorder's job

The harness does **not** hand-roll WAL/checkpoint/health gauges. pgfr already records the full
server-side time-series continuously, WAL bytes + write/sync time, checkpoints, `pg_stat_io`
(client/checkpointer/autovacuum/bgwriter reads+writes+fsyncs), wait/lock events, table sizes, 
so the harness records the phase-boundary timestamps and the report slices pgfr's series to the
conversion window (`pgfr_analyze.incident_timeline`). pgfr needs `pg_cron` + `pg_stat_statements`
preloaded (both true on Supabase). With `BENCH_PGFR=0` you get client-side latency + the pgpm
conversion summary, but no system-metric time-series; set `BENCH_PGFR=1` for the full picture.

## Interpreting the results

- **convert** is the window that matters: pgpm is premaking + draining the default while
  the ambient workload runs. p50/p95 should stay close to baseline; the conversion is
  online. Expect occasional `max` blips: the brief `ACCESS EXCLUSIVE` on the adopt cutover,
  and pgpm's partition `ATTACH`es. If `max` is large or sustained, that's a real finding
  worth chasing (e.g. the adopt's prep wasn't done, so the PK index built in-transaction).
- **drain progress** is in `drain.progress.csv`: the default shrinks as pgpm drains the
  closed months, then *grows* once they're gone (the open/current month stays in the
  default and the ambient workload keeps filling it): that's the drain reaching "settled."
- **post** reflects the post-conversion steady state; pgpm tuned autovacuum aggressively on
  the default at adopt, so dead tuples from the drain reclaim over time. The table is larger
  than at baseline (the workload kept inserting), so compare latency *shape*, not just tps.
- The conversion runs **server-side via pg_cron** (the harness only observes), so a dropped
  observer connection is harmless (it retries; pgpm keeps draining).

> Re-running against the **same** database needs a reset first
> (`drop schema bench cascade; drop schema pgpm cascade;`), the harness never drops
> data on its own, so it won't clobber a real target.

## Prerequisites

- `psql` and `pgbench` on `PATH` (or set `PSQL` / `PGBENCH`).
- Target server has `pg_cron` (required by pgpm) and ideally `pg_stat_statements`.
- Enough disk for the target table size **plus** drain headroom (the drain copies
  each historical month into a new partition before the default shrinks).
