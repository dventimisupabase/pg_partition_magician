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

## The phases

1. **baseline**: steady workload against the *unpartitioned* table.
2. **adopt**: fire `pgpm.adopt()` while the workload runs; time the (metadata-only) cutover.
3. **drain**: loop `pgpm.drain_step()` to move the historical months into real
   partitions, *under continuous load*; sample default-size / dead-tuples / partition
   count over time.
4. **post**: steady workload against the now-partitioned table.

The report compares tps, average + p50/p95/p99 latency, and health gauges across
all four phases so any degradation during adopt/drain is visible.

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

## Knobs

| env | default | meaning |
|-----|---------|---------|
| `BENCH_DSN` | *(PG\* env)* | libpq conninfo / URI (never logged) |
| `BENCH_ROWS` | `300000000` | target rows in `bench.events` |
| `BENCH_MONTHS` | `12` | months of history to spread across |
| `BENCH_CHUNK` | `2000000` | generator commit chunk |
| `BENCH_GEN_JOBS` | `1` | parallel generator sessions: set to ≈vCPU to fan generation across cores (one `INSERT…SELECT` is single-core-bound) |
| `BENCH_DEFER_INDEX` | `0` | drop the secondary index during bulk load, rebuild after; avoids scattered per-row index maintenance across hundreds of millions of inserts |
| `BENCH_PREPARE_ADOPT` | `0` | build the PK index `CONCURRENTLY` online (a new `prepare` phase, under load) before `adopt`, so the cutover is metadata-only. **Essential at scale**: otherwise `adopt` builds the index in-transaction under `ACCESS EXCLUSIVE` (a multi-minute write-blocking window on a 100GB+ table) |
| `BENCH_INTERVAL` | `1 month` | partition width |
| `BENCH_PREMAKE` | `3` | future partitions to premake at adopt |
| `BENCH_CLIENTS` / `BENCH_JOBS` | `16` / `4` | pgbench concurrency |
| `BENCH_OPS` | `50` | server-side ops per `workload_step` call |
| `BENCH_PHASE_SECS` | `120` | baseline/post load duration |
| `BENCH_OPS` | `50` | server-side ops per `workload_step` call, **calibrate to scale**: each op is disk-bound (~hundreds of ms) once the table exceeds RAM, so a value tuned on a cached table will blow `statement_timeout` at scale. Keep it small (e.g. 5–10) for >RAM tables |
| `BENCH_MAX_FAIL_PCT` | `5` | abort right after baseline if more than this % of transactions failed (catches a mis-calibrated `BENCH_OPS` in minutes instead of hours) |
| `BENCH_DRAIN_BATCH` | `20000` | rows per `drain_step` |
| `BENCH_DRAIN_SLEEP` | `0` | pause between drain steps (s); `0` = full speed |
| `BENCH_DRAIN_MAX_SECS` | `3600` | safety cap on the drain window |
| `BENCH_PGFR` / `BENCH_PGFR_DIR` | `0` / `bench/vendor/pg_flight_recorder` | install + enable pg_flight_recorder (record + analyze) for WAL/checkpoint/wait telemetry; clone the repo into `BENCH_PGFR_DIR` first |
| `BENCH_SKIP_GENERATE` | `0` | reuse already-loaded data |

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

- `report.md`: the before/during/after comparison: tps, latency percentiles,
  health, and **WAL/checkpoint deltas** per phase.
- `<phase>.pgbench.txt`: raw pgbench summary (tps, latency average).
- `<phase>.pctiles.txt`: p50/p95/p99/max from the per-transaction log.
- `<phase>.pgss.csv`: top server-side statements (WAN-free timing).
- `<phase>.health.csv`: table size, dead tuples, partition count, active backends.
- `<phase>.wal.csv`: WAL LSN + WAL records/FPI + checkpoint counters at the phase
  boundary; the report diffs consecutive phases into per-phase write-pressure deltas.
- `drain.progress.csv`: default-partition drain curve under load.
- **pg_flight_recorder** (when `BENCH_PGFR=1`): `<phase>.pgfr_deltas.csv` (snapshot
  deltas, WAL/checkpoint/IO), `<phase>.pgfr_waits.csv` (wait events), and
  `pgfr_report.md` (the full-run `pgfr_analyze` narrative: anomalies, wait summary,
  WAL/checkpoint snapshots over time).

> `bench/results/` is git-ignored except for committed example reports.

### WAL / checkpoint gauges

Two layers, complementary:

- **Bespoke (always on, no superuser):** an exact per-phase WAL-bytes figure from a
  `pg_current_wal_lsn()` boundary diff, plus WAL records/FPI and checkpoint counts
  (`pg_stat_checkpointer` on PG17+, else `pg_stat_bgwriter`). The drain is the WAL-heavy
  phase (microbatch delete+insert); this quantifies it.
- **pg_flight_recorder (`BENCH_PGFR=1`):** pgfr already samples WAL/checkpoint/IO and wait
  events continuously into `pgfr_record.snapshots_v` / `deltas`, so the harness reads its
  series per phase and emits the `pgfr_analyze` narrative. pgfr needs `pg_cron` +
  `pg_stat_statements` preloaded (both true on Supabase); if it can't install, the run
  continues on the bespoke gauges alone.

## Interpreting the results

- **adopt** should show tps ~unchanged from baseline: it's metadata-only. Expect a
  single large `max` latency: the brief `ACCESS EXCLUSIVE` lock on the rename/attach.
  p95/p99 stay close to baseline (only the handful of txns caught in that window pay).
- **drain** runs fully online; p50/p95 stay low. The `max` tail comes from rare txns
  queued behind a partition `ATTACH` lock under contention. Raise `BENCH_DRAIN_SLEEP`
  (e.g. `0.25`) to pace the drain and shrink that tail at the cost of a longer drain.
- **post** is measured after a `VACUUM (ANALYZE)` so it reflects steady state, not the
  drain's transient dead tuples. The table is larger than at baseline (the load kept
  inserting throughout), so compare latency shape, not just absolute tps.
- A clean run preserves every row: final `count(*)` = generated + inserted-under-load.

> Re-running against the **same** database needs a reset first
> (`drop schema bench cascade; drop schema pgpm cascade;`), the harness never drops
> data on its own, so it won't clobber a real target.

## Prerequisites

- `psql` and `pgbench` on `PATH` (or set `PSQL` / `PGBENCH`).
- Target server has `pg_cron` (required by pgpm) and ideally `pg_stat_statements`.
- Enough disk for the target table size **plus** drain headroom (the drain copies
  each historical month into a new partition before the default shrinks).
