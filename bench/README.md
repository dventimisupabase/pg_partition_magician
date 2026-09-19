# At-scale load test

Proves `pg_partition_magician` converts a **giant, live, query-loaded** table to
partitioned **online**, and measures latency / throughput / health *before*,
*during*, and *after* the conversion.

> **Model note: monolith + regrain.** Since the redesign, `transmute()` is an instant metadata cutover
> that parks all history in one bounded *monolith* partition; the bulk O(rows) move is now `regrain()`
> (COPY the monolith into fine children, one atomic swap, drop the source), not the drain. `regrain`
> only runs on a *frozen* coarse child (whole range below the write frontier). A time key's frontier is
> wall-clock `now()`, so a fresh time monolith cannot freeze inside a benchmark window; an id key's
> frontier is `max(id)`, which the harness advances past the monolith's upper bound with one sentinel
> row to freeze it on demand (the same trick pgpm's own regrain tests use). So the harness partitions
> `bench.events` by its bigint `id` (it is in the PK, so `transmute` reuses the PK in place) and
> measures the regrain of the id-monolith under load. A rung is green when regrain completes
> (`coarse_partitions` reaches 0), every history row is conserved across the swap, and convert-phase
> latency tracks baseline with zero workload failures.

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

pgpm is **self-driving**: you call `transmute()` once, enable auto-regrain, and pgpm's own pg_cron
maintenance regrains the monolith (and obtains) autonomously, inside the database. So this
harness does **not** perform the partitioning: it sets pgpm up the way an operator would, drives an
ambient workload, and *observes*. Three phases:

1. **baseline**: ambient workload against the *unpartitioned* table.
2. **convert**: fire `pgpm.transmute()` once (`p_paused => false`), freeze the monolith (advance the id
   frontier past it with a sentinel row), enable auto-regrain (`set_regrain`), and schedule
   `pgpm.maintain` on pg_cron. Then **pgpm** regrains the monolith into fine partitions on its own
   (COPY into new children, one atomic swap, drop the source) while the harness drives the workload and
   watches `pgpm.log` until the regrain completes (`coarse_partitions` reaches 0). The harness never
   calls `regrain_step`; because the conversion runs server-side, a dropped harness connection can't
   stop it.
3. **post**: ambient workload against the now fully-partitioned table.

The report compares client tps + p50/p95/p99 latency across the three phases, summarizes pgpm's own
conversion (regrain/obtain from `pgpm.log`), and asserts **row conservation** (every history row still
present after the swap). The system-metric time-series (WAL, checkpoints, `pg_stat_io`, wait/lock
events) is **pg_flight_recorder's** job: it records them continuously and server-side, and the report
slices its series to the conversion window. So degradation *while pgpm converts the table under load*
is visible without the harness hand-rolling gauges.

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
| `BENCH_INTERVAL` | `1 month` | partition width (time-key only; the ladder partitions by `id`, see `BENCH_ID_STEP`) |
| `BENCH_ID_STEP` | `10000000` | id-grid step: the bench partitions `bench.events` by its bigint `id`; the monolith `[0,B)` regrains into ~`B/step` fine partitions |
| `BENCH_REGRAIN` | `1` | `1` = freeze the monolith and drive auto-regrain (the bulk mover) and observe it to completion; `0` = transmute-only (no bulk move) |
| `BENCH_OBTAIN` | `3` | future partitions pgpm obtains (configured on transmute; pgpm's maintenance does it) |
| `BENCH_CLIENTS` / `BENCH_JOBS` | `16` / `4` | ambient-workload pgbench concurrency |
| `BENCH_OPS` | `50` | server-side ops per `workload_step` call, **calibrate to scale**: each op is disk-bound (~hundreds of ms) once the table exceeds RAM, so a value tuned on a cached table blows `statement_timeout` at scale. Keep it small (e.g. 5–10) for >RAM tables |
| `BENCH_PHASE_SECS` | `120` | baseline/post observation duration |
| `BENCH_MAX_FAIL_PCT` | `5` | abort right after baseline if more than this % of transactions failed (catches a mis-calibrated `BENCH_OPS` in minutes instead of hours) |
| `BENCH_MAINT_INTERVAL` | `5 seconds` | pg_cron schedule for both maintenance jobs (`pgpm.maintain_all` and `pgpm.maintain_obtain_all`), how often pgpm drives a tick |
| `BENCH_OBSERVE_INTERVAL` | `15` | how often (s) the harness samples while pgpm works |
| `BENCH_DRAIN_IDLE_SECS` | `120` | transmute-only runs (`BENCH_REGRAIN=0`): stop observing after this long, since there is no regrain to wait for |
| `BENCH_DRAIN_MAX_SECS` | `3600` | safety cap on the observation window |
| `BENCH_OBSERVE_MODE` | `settle` | `settle` = observe until the regrain fully completes (0 coarse children); `window` = warm up then measure a fixed window without waiting for completion (see Profiles) |
| `BENCH_CONVERT_WARMUP_SECS` | `30` | window mode: let the regrain reach steady state before measuring |
| `BENCH_CONVERT_WINDOW_SECS` | `300` | window mode: measure the workload for this long, then stop (regrain left running) |
| `BENCH_PGFR` / `BENCH_PGFR_DIR` | `0` / `bench/vendor/pg_flight_recorder` | install + enable pg_flight_recorder (record + analyze) for WAL/checkpoint/wait telemetry; clone the repo into `BENCH_PGFR_DIR` first |
| `BENCH_SKIP_GENERATE` | `0` | reuse already-loaded data |

## Profiles (one engine, different questions)

A single benchmark can't be everything at once, *aggressive* (to find limits and bugs) and
*gentle* (to show the conversion is unnoticeable) and *complete-in-a-window* and *at-scale* are
contradictory demands. So `bench/run_rung.sh <rung> [profile]` runs the same engine under named
profiles that bundle drive-intensity + how we observe:

- **`stress`** (default), aggressive regrain (2 s maintenance, large batch), **run to completion**
  (`BENCH_OBSERVE_MODE=settle`): drive the regrain hard so it finishes within the run, then confirm
  it settled. This is the *stress test*, it deliberately exceeds production load to surface
  bugs and limits, and it's how most of pgpm's conversion/obtain hardening was found.
- **`gentle`**, representative regrain (20 s maintenance, small batch sized **under `work_mem`** so
  it never spills temp), **windowed** (`BENCH_OBSERVE_MODE=window`): warm up until the regrain is
  steadily running, then measure the workload over a fixed window and compare it to baseline,
  *without* waiting for completion (a gentle regrain of a large table takes hours/days and doesn't
  need to finish to answer "is it unnoticeable?"). Kept under the instance's I/O baseline, so the
  EBS burst never depletes and the measurement is reproducible.

The two are complementary, not competing: throttling needs no pgpm change (it's just the regrain batch size,
`BENCH_DRAIN_BATCH`, passed to `transmute` as `p_regrain_batch`, and the maintenance cadence, pgpm's intended gentle mode), and the stress arm earns its keep as a
bug-finder. Profiles compose with the size ladder as a *rung × profile* matrix; results land in
`results/<rung>-<profile>/`.

## Faster reruns

The expensive setup is **generation** (~minutes/10s-of-GB, CPU-bound on `md5()`) and the
**online PK index build** (`prepare` phase, ~tens of minutes on a 100GB+ table). Two ways
to cut that on repeat runs, with an honest caveat on each:

- **Scale the instance up for setup, down to measure (the bigger lever).** Generation is
  CPU/IO/`maintenance_work_mem`-bound, so a larger compute tier builds it far faster, and it is
  *setup*, not the measurement, so speeding it up doesn't affect the >RAM realism. The regrain (the
  long pole) is the measurement and must stay on the target tier. Compute resize is a **restart**, so
  this can't happen mid-run: do it as *scale up -> generate -> scale down (restart) ->
  `BENCH_SKIP_GENERATE=1` measurement run*. transmute itself is always a metadata-only cutover (it never
  rewrites the PK), so there is nothing to pre-build.

- **Reuse the generated data (`BENCH_SKIP_GENERATE=1`).** Keep an untouched seed copy of the
  rows so you don't pay `md5()` generation again:

  ```sql
  -- once, after the first generation (before transmute):
  create table bench.events_seed as select * from bench.events;
  -- before each rerun (transmute is destructive, it partitions bench.events):
  drop table if exists bench.events cascade;
  create table bench.events (like bench.events_seed including defaults);
  alter table bench.events add column id bigint generated by default as identity primary key;
  insert into bench.events (created_at, user_id, kind, payload)
    select created_at, user_id, kind, payload from bench.events_seed;
  ```

  **Caveat:** this banks only the *data*; a copy is faster than regeneration (no `md5()`),
  but the PK index build is per-conversion and can't be reused (`transmute` consumes it), and the
  seed doubles disk. So it saves the generation time, not the index-build time. The scale-up
  approach above is what speeds the index build.

## Output (`bench/results/`)

- `report.md`: the before/during/after comparison, client tps + latency percentiles per
  phase, a summary of pgpm's own conversion (regrain copy/swap and obtain counts, rows copied,
  coarse children remaining, from `pgpm.log`), a row-conservation check, and a pointer to the pgfr system-metric series sliced to the
  conversion window.
- `<phase>.pgbench.txt`: raw pgbench summary (tps, latency average).
- `<phase>.pctiles.txt`: client p50/p95/p99/max from the per-transaction log.
- `<phase>.pgss.csv`: top server-side workload statements per phase (a scoped
  `pg_stat_statements` reset/dump, WAN-free timing for the workload itself).
- `drain.progress.csv`: the regrain progress curve under load (observed_s, coarse,
  regrain_copies, rows_copied, last_regrain_age_s, ...), pgpm's own conversion progress. The
  file keeps its historical name; its columns track regrain.
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

When pgfr is present, `pgpm_core`'s built-in correlation functions read that same telemetry from pgpm's
side, which is handy for reading a `BENCH_PGFR=1` run: `pgpm.impact_report('bench.events')` summarizes what
the conversion did to the workload over the window pgpm was active (forced checkpoints, WAL, top waits,
query latency). The correlation has its own test track (`./test.sh observe`); see the
[reference](../docs/reference.md#observability-with-pg_flight_recorder-observe).

## Interpreting the results

- **convert** is the window that matters: pgpm is obtaining + regraining the monolith while
  the ambient workload runs. p50/p95 should stay close to baseline; the conversion is
  online. Expect occasional `max` blips: the brief `ACCESS EXCLUSIVE` on the transmute cutover,
  and pgpm's partition `ATTACH`es. If `max` is large or sustained, that's a real finding
  worth chasing (e.g. the transmute's prep wasn't done, so the PK index built in-transaction).
- **regrain progress** is in `drain.progress.csv`: `rows_copied` climbs as pgpm copies the
  monolith into fine children, and `coarse` drops from 1 to 0 at the atomic swap: that's the
  regrain reaching "settled."
- **post** reflects the post-conversion steady state. Regrain copies rather than deletes, so it
  leaves no dead tuples behind to reclaim. The table is larger
  than at baseline (the workload kept inserting), so compare latency *shape*, not just tps.
- The conversion runs **server-side via pg_cron** (the harness only observes), so a dropped
  observer connection is harmless (it retries; pgpm keeps regraining).

> Re-running against the **same** database needs a reset first
> (`drop schema bench cascade; drop schema pgpm cascade;`), the harness never drops
> data on its own, so it won't clobber a real target.

## Prerequisites

- `psql` and `pgbench` on `PATH` (or set `PSQL` / `PGBENCH`).
- Target server has `pg_cron` (required by pgpm) and ideally `pg_stat_statements`.
- Enough disk for the target table size **plus** regrain headroom (regrain copies the
  monolith into fine partitions before the swap drops it, so history briefly exists twice).

## Timing instruments (not guards, issue #345)

Two scripts measure a named phase's duration, attributed to buckets rather than one wall-clock
number, so a slowdown can be pinned to *which* step grew. Neither is wired into `./test.sh
perf`/`discriminate`: there is no known-good threshold to assert against, so each is evidence for
a decision, not a guard against a regression.

- **`transmute_cutover_timing.sh <container> <db_prefix> [install.sql]`** -- transmute's phase 3
  (the cutover). Each fixture case gets its own throwaway database (`<prefix>_<case>`), since
  transmute only runs once per table.
- **`regrain_swap_timing.sh <container> <db_prefix> [install.sql]`** -- the sibling for
  `regrain_step`'s swap. A different fixture (an already-transmuted table with a resumable
  regrain), not an extension of the cutover script.

`io_burst_probe.sh` is unrelated to either: a standalone disk-IO burst discriminator, measuring by
direct wall-clock timing of bounded units against a lake that exceeds RAM, so reads hit disk. Tells
a steady-state volume (flat throughput/IOPS) from one that bursts and then steps down once its
credits deplete.

```bash
MODE=iops bench/io_burst_probe.sh
MODE=throughput LAKE_GB=100 bench/io_burst_probe.sh
```

## Migrating a TimescaleDB hypertable (`run_fh.sh`)

`bench/run.sh` converts a plain id-keyed table with `transmute` + `regrain`.
**`bench/run_fh.sh`** is its sibling for the `from_hypertable` path: it converts a
TimescaleDB **hypertable** (Apache edition, the Supabase fleet) to pgpm-managed native
partitioning, online, under live OLTP load. It needs **PostgreSQL 15 with Apache
TimescaleDB** (timescaledb is deprecated on PG17), plus `pg_cron` and ideally
`pg_stat_statements` and `pgtap`. The local `supabase/postgres:15` image and Supabase
green PG15 both qualify.

### What it does

Same passive-observer model as `run.sh`, but the candidate `bench.events` is built as a
time-partitioned **hypertable** (keyed: the PK includes the `created_at` control column,
with an identity `id` and a secondary index), and the conversion is `from_hypertable`,
exposed as two phases so writes keep arriving across them. Three observed phases:

1. **baseline**: ambient workload against the live hypertable.
2. **convert**:
   - `from_hypertable_copy(..., p_track_changes => true)`: online copy into one plain
     destination, chunk by chunk, while the source stays live; an AFTER-row trigger logs every
     in-flight insert/update/delete.
   - `from_hypertable_cutover(...)`: a brief `ACCESS EXCLUSIVE` window that catches up and
     reconciles the delta, drops the hypertable, renames the copy into place, rebuilds the
     key/indexes/identity, and hands off to `transmute`. (At scale this window is **not**
     negligible: `CREATE TABLE LIKE` carries no indexes, so the rebuild of the PK and
     secondary index on the full table happens inside it.)
   - **regrain**: split the resulting time-monolith into `BENCH_FH_INTERVAL` partitions (see
     the wall-clock note below).
3. **post**: ambient workload against the now pgpm-partitioned table.

### Conservation under continuous load

An exact total-row count can't be asserted while the workload mutates rows, so
`bench.workload_step_fh` only ever touches users `1..49000` and reserves users
`49001..50000` as an **immutable cohort** spread across all of history. The harness
asserts that cohort is unchanged across the migration: a clean "no rows lost or
duplicated" check even under continuous insert/update/delete. (Delta-reconcile
*correctness* is covered by the pgTAP suite, `tests/timescale/db/10`; the bench measures
at-scale behavior and load, not correctness.)

### Regrain and the wall-clock frontier (a bench instrument)

pgpm regrains a partition only once the write frontier has passed its upper bound, and for
a **time** key the frontier is wall-clock `now()`. A `from_hypertable` monolith spans
`[min, next-period-boundary]`, so its upper bound is in the future and it is the *active
current partition*: pgpm correctly refuses to regrain it until the calendar rolls past the
boundary. To exercise regrain inside a bench window, `run_fh.sh`:

- runs the regrain-phase workload at an effective clock pushed **past** the monolith (the
  `p_clock_secs` argument), so its writes land in **forward** partitions and the monolith
  range stays quiescent, and
- drives `regrain_history` in a session whose `now()` is shadowed to a future time (a
  `shadow.now()` in a schema ahead of `pg_catalog`; pgpm functions do not pin
  `search_path`).

This is a **bench instrument only**: it lets pgpm act on a genuinely-quiescent historical
range as if frozen. In production you never do this; the monolith regrains naturally as the
calendar advances.

### Running it

```bash
# local smoke (supabase/postgres:15 -- PG15 + Apache timescaledb + pg_cron + pgtap; the `timescale`
# compose service, `docker compose --profile timescale up -d`, maps host port 5519)
BENCH_DSN='postgres://postgres:postgres@localhost:5519/postgres' \
  BENCH_ROWS=20000 BENCH_MONTHS=3 BENCH_CHUNK_INTERVAL='1 week' BENCH_FH_INTERVAL='1 month' \
  BENCH_PHASE_SECS=8 BENCH_CLIENTS=4 BENCH_OPS=5 \
  bench/run_fh.sh

# at scale on a green PG15 instance (Apache timescaledb), via the session pooler
BENCH_DSN='postgresql://postgres.<ref>:...@aws-0-<region>.pooler.supabase.green:5432/postgres?sslmode=require' \
  BENCH_ROWS=40000000 BENCH_MONTHS=6 BENCH_CHUNK_INTERVAL='1 day' BENCH_FH_INTERVAL='1 month' \
  BENCH_GEN_JOBS=8 BENCH_CLIENTS=16 BENCH_PGFR=1 BENCH_PGFR_DIR=bench/vendor/pg_flight_recorder \
  bench/run_fh.sh
```

`from_hypertable` is a procedure that COMMITs, so the harness drives it as top-level
`CALL`s. Run the driver close to the database: over a WAN the client tps is round-trip
bound, so read the result through the **server-side** signals (the conversion timings,
conservation, and pgfr/pgss latency), not client tps.

### Knobs (in addition to the shared `BENCH_*` above)

| env | default | meaning |
|-----|---------|---------|
| `BENCH_CHUNK_INTERVAL` | `1 week` | hypertable chunk width (sets how many chunks the copy iterates) |
| `BENCH_FH_INTERVAL` | `1 month` | pgpm partition width `from_hypertable` transmutes to, and the regrain target |
| `BENCH_TRACK_CHANGES` | `1` | install the delta trigger so in-flight update/delete are reconciled at cutover (needs a key; refused on a keyless table) |
| `BENCH_REGRAIN` | `1` | after cutover, regrain the time-monolith via the now()-shadow instrument; `0` = stop after cutover |
| `BENCH_OBTAIN` | `4` | forward partitions obtained at cutover |
| `BENCH_DRAIN_BATCH` | `50000` | rows per regrain microbatch; also the cutover pre-drain's micro-batch size and residual threshold |
| `BENCH_DRAIN_MAX_SECS` | `1800` | safety cap on the regrain observation window |
| `BENCH_PREDRAIN` | `1` | `1` = the cutover pre-drains the delta online before the lock (`p_predrain=>true`); `0` = undrained (the #170 A/B) |
| `BENCH_LOCKPROBE` | `1` | arm a background `pg_locks` session that times the cutover's true `ACCESS EXCLUSIVE` window and reads the at-lock delta residual |

`BENCH_ROWS`, `BENCH_MONTHS`, `BENCH_GEN_JOBS`, `BENCH_CLIENTS`/`BENCH_JOBS`, `BENCH_OPS`,
`BENCH_PHASE_SECS`, `BENCH_PGFR`/`BENCH_PGFR_DIR`, and `BENCH_SKIP_GENERATE` behave as in
`run.sh`.

### Measuring the cutover lock window (#170)

With change tracking on, the cutover reconciles the captured delta. The online pre-drain
(`p_predrain`, default on) chases that backlog down **before** taking the lock, so the
`ACCESS EXCLUSIVE` window applies only a tiny residual instead of the whole online-copy
backlog. To quantify it, run the **same rung twice on fresh instances** (the
fresh-instance-per-run rule) and compare the report's `## cutover lock window` section:

```bash
BENCH_PREDRAIN=1 bench/run_rung_fh.sh R3   # drained: residual ~ drain_batch, window flat
BENCH_PREDRAIN=0 bench/run_rung_fh.sh R3   # undrained: residual == whole backlog, window grows with the copy
```

The window is timed by a background `pg_locks` probe (the whole cutover `call` also includes
the pre-drain + the O(rows) index pre-build, so `cut_secs` overstates the blocking window).
Climbing rungs with `BENCH_PREDRAIN=0` shows the undrained window tracking copy duration;
with `=1` it stays bounded. pgfr's `lock_samples` corroborate qualitatively only (its 60 s
cadence cannot resolve the window, especially the drained arm).

### Output

The same `bench/results/` layout (`report.md`, per-phase `*.pgbench.txt`/`*.pctiles.txt`/
`*.pgss.csv`, and pgfr when enabled), plus `copy.progress.csv` (the online copy: dest rows
and pending delta keys over time), `regrain.progress.csv` (coarse children counting down
to 0), and `lockprobe.log` (the cutover lock-window probe's `LOCKPROBE …` line).

## Instruments for a customer's own table (`pilot_workload.sql`, `transmute_online.sh`)

Everything above drives pgpm's own fixtures at scale. These two drive a **customer's** table over a
DSN, and they exist for one specific question that the rest of the suite cannot ask.

An idle clone establishes that a conversion is correct: that the schema survives it, that rows survive
by identity, that regrain and (for a time-like key) obtain and retention do real work. It cannot
establish that the conversion is **online**, because "no reader or writer was blocked" is trivially
true where there are none -- that needs a live workload against the clone, which is what these two
drive.

```bash
# 1. Generate a workload for the target table. Introspects the catalog and builds
#    pgpm_probe.step() for this table specifically.
psql "$DSN" -f bench/pilot_workload.sql
psql "$DSN" -c "call pgpm_probe.install('public.events','created_at')"

# 2. Convert under load, and measure. The table IS converted when this returns.
bench/transmute_online.sh "$DSN" public.events created_at '1 month'

# 3. Remove the apparatus. Leaves the converted table and pgpm alone.
psql "$DSN" -c "drop schema pgpm_probe cascade"
```

### Why the workload generates itself

`workload.pgbench` calls `bench.workload_step()`, which only knows the bench schema. A customer table
has its own columns, NOT NULLs, foreign keys, checks and identity columns, so the insert has to come
from the catalog. It is built by **copying an existing row with the control column overridden**, which
satisfies every NOT NULL, FK and CHECK by construction, because the template row already satisfies
them. Identity and generated columns are omitted so their defaults fire, which is also what stops a
copied row colliding on a surrogate key. `install()` then **dry-runs the generated INSERT and rolls it
back**, so a statement that would fail at run time is caught at setup instead of showing up later as
"the writer was blocked", which is the one conclusion this whole apparatus exists to draw.

Three things worth knowing about the generated workload:

- **One insert and one read per transaction, deliberately.** Not a batch, unlike `workload.pgbench`.
  Locks are held to transaction end, so a step that wrote N rows would hold ROW EXCLUSIVE across all of
  them, transmute's ACCESS EXCLUSIVE would queue behind it, and every later reader would queue behind
  that. The workload would be starving the conversion it is supposed to be competing with.
- **`uuidv7` needs its own value generator.** `pgpm._ts_to_uuid` zero-fills the tail because it encodes
  partition *bounds*, so two calls in the same millisecond return the same uuid and collide on a primary
  key. `pgpm_probe.uuidv7_now()` keeps the 48-bit millisecond prefix the grid reads and randomises the
  rest.
- **A failed `install()` leaves nothing runnable.** It drops the previous `step()` first. A surviving
  one points at a *different* table, and a workload driving the wrong table looks exactly like a
  workload driving the right one. That happened while this was being written.

### What the probe asserts, and how it is known to discriminate

`transmute_online.sh` is not a CI guard. `transmute_lock.sh` is the CI guard for the same property,
with its own fixture and a mutation behind `./test.sh discriminate`. This is the field instrument, and
it cannot run in CI because it needs a target database and a workload. It carries its own
discrimination at run time instead: three of its nine assertions exist only to establish that the
conditions for the others were present.

- The workload was committing writes **before** the conversion, and again **during** it. Without both,
  every other assertion passes vacuously, which is rung 0a wearing a rung 0b label.
- The probe **caught the validation scan in progress**. A probe that samples after the window closes
  reports "nothing held" against arbitrarily broken code.
- No ACCESS EXCLUSIVE **granted** during the scan. `granted` matters here in a way it does not for the
  CI guard: with a workload running, transmute's own AEL request legitimately queues behind the
  workload's ROW EXCLUSIVE and appears in `pg_locks` ungranted. Counting a pending request as a held
  lock would fail this against correct code.
- No writer **queued** at the moment the scan was running. ROW EXCLUSIVE does not conflict with the
  scan's SHARE UPDATE EXCLUSIVE, so a queued writer is queued behind something that should not be
  there. A lock-state assertion, not a wall-clock one, so there is nothing to flake.

Verified in all three directions, on PG 17 against a 3M-row table:

| run against | result |
| --- | --- |
| real `install.sql` | 9/9 pass, 2000 writes committed during the conversion window |
| the `transmute_no_commits` mutant | fails: ACCESS EXCLUSIVE granted during the scan, and writers queued |
| a workload that commits nothing | refuses to convert at all, on the pre-conversion liveness check |

One calibration note from that mutant run: at 3M rows the lock-mode and queued-writer assertions failed
while "no writer failed" still passed, because the stall stayed inside the workload's `lock_timeout`.
The lock-state assertions detect the defect at any table size; the writer-failure count only fires once
the stall exceeds a real client's patience. Keep all of them.

### Knobs

| variable | default | meaning |
| --- | --- | --- |
| `PILOT_CLIENTS` | 4 | pgbench clients |
| `PILOT_WARMUP` | 5 | seconds of workload before converting |
| `PILOT_LOCK_TIMEOUT` | `2s` | the workload's own `lock_timeout` |
| `PILOT_TX_LOCK_TIMEOUT` | `5s` | `p_lock_timeout` passed to transmute |
| `PILOT_BOUND_HEADROOM` | 1 | `p_bound_headroom`. Defaults ON, unlike transmute's own 0: the monolith bound rejects writes at or past `hi` for the whole conversion, so a writer at the frontier can cross it if the conversion spans a grid boundary (a daily step converted at 23:59). This is the pattern a live production conversion should use too. |

## Lock-sequence renderer (`bench/lock_view.sh`, issue #392)

Draws a **picture** of a maintenance tick's lock sequence, for a human to look at. It is
**not** a guard over pgpm: it asserts nothing about the extension's behaviour and blocks no
merge on it. `bench/lock_trace.sh` is that guard (it runs in `./test.sh locktrace` and answers
a yes/no question with eBPF); this tool answers "what actually happened, in what order, on
which relations" by turning the same kind of eBPF capture into a timeline you can read.

CI does run it, on itself. `./test.sh lockview` drives this harness end to end and then runs all
three discrimination proofs (the request/return pairing, the enlistment primer, and the
schema-scoped name fold), and `.github/workflows/lockview.yml` runs that track on every PR touching
a lock-view file, so the **instrument** is guarded even though the thing it measures is not
(issue #398). The distinction is the whole point: nothing ships on a figure, but an instrument
that fabricates a grant tells its reader the confident opposite of the truth.

### Invocation

```bash
bench/lock_view.sh <container> <db> <relations> <sql> [run-name]

# example: watch mg_ret and ml through one maintenance tick
bench/lock_view.sh pgpm_test-locktrace mydb 'public.mg_ret,public.ml' \
  "call pgpm.maintain_all()" mytick
```

`<relations>` is a comma-separated list of `schema.table` names to enlist (their oids are
looked up at the start of the run); `<sql>` is the statement to trace. The harness snapshots
relation names before and after the traced statement, runs the probe, executes `<sql>`, waits
for the probe to drain, then renders the two figures.

### A primer mark you will see on the figure

`bench/lock_view.py` enlists a backend into its watched set only once that backend touches one of
the enlisted oids, so any lock the SAME backend took EARLIER in `<sql>` would otherwise be lost
outright and rendered as though the sequence were complete (issue #392 review, finding 1):
`LOCK other; LOCK target;`, traced as one statement, would drop `other` with no refusal to catch
it. `lock_view.sh` closes this for the one relation it can reach ahead of time: immediately before
`<sql>` runs, it issues `select 1 from <first-enlisted-relation> limit 0` as its own statement, in
the SAME `docker exec ... psql -c ... -c ...` invocation (one backend, one pid) that then runs
`<sql>`. That backend is enlisted before `<sql>` executes anything at all.

Two things follow, both worth knowing before reading a figure:

- **The primer takes a real AccessShare lock, and it will appear in the capture.** It is the
  FIRST AccessShare mark on the first enlisted relation, and it is an artifact of this harness, not
  part of `<sql>`'s own work. Do not read it as something the traced statement did.
- **It renders INSIDE the shaded `[t_begin, t_end]` band, not before it.** `t_begin` is recorded on
  the host before the single `docker exec` that runs the primer and `<sql>` back to back; there is
  no point at which this script can record a timestamp between them without splitting them into
  separate psql invocations, which would give them separate backends and defeat the whole point of
  priming. So the ordinary rule ("locks before `t_begin` are outside the band, ambient noise") does
  not apply to this one mark -- it is inside the band by construction, and the first AccessShare on
  the first enlisted relation is how you recognise it.
- **Only when it is safe.** If the first enlisted relation cannot be selected from (dropped
  mid-run, no privilege, whatever), the primer's own statement fails and `<sql>` still runs; a
  primer failure never aborts the run or gets mistaken for `<sql>` itself failing.

**What this does NOT close.** A lock the SAME backend held before the primer ever ran cannot exist
within one fresh `psql` invocation, so there is nothing to miss there. But a lock taken by a
DIFFERENT backend, before THAT backend first touches a target relation, is still invisible --
priming enlists only the one backend running `<sql>`; every other session on the server is
enlisted the same way this tool always enlisted anyone, on first touch. Read a figure as a complete
suffix of the one backend under test from the moment it was primed, never as a complete prefix of
every backend's own locking. See `bench/lock_view.py`'s module docstring for the same limit stated
next to the code it applies to, and `bench/lock_view_names_scope_demo.sh`'s sibling script,
`bench/lock_view_prefix_demo.sh`, for a runnable demonstration against a live capture.

### Prerequisites

- The `locktrace` compose profile, up and healthy: `docker compose --profile locktrace up -d`.
  This is the same privileged, eBPF-capable container `./test.sh locktrace` uses; nothing here
  needs a second image.
- A Python virtualenv with matplotlib, at `.venv-lockview/` (gitignored, created on demand):

  ```bash
  python3 -m venv .venv-lockview
  .venv-lockview/bin/pip install matplotlib
  ```

  This has to be a venv rather than a plain `pip install matplotlib` against the system
  interpreter: PEP 668 marks a Homebrew (or distro-managed) Python as externally managed and
  refuses the install outright, precisely to stop a `pip install` from silently rewriting
  packages the OS itself depends on. The renderer (`bench/plot_lock_view.py`) imports
  matplotlib at module scope, so both it and `bench/lock_view_selftest.py` have to run under
  this venv's interpreter, never the system `python3`:

  ```bash
  .venv-lockview/bin/python bench/lock_view_selftest.py
  ```

  Do not reuse `.venv-verify/`; that one belongs to the archive track's own toolchain
  (pyarrow, duckdb) and conflating the two makes either one's rebuild a surprise for the other.

### Output

Each run writes a timestamped directory, `bench/results/lockview-<run-name>-<YYYYmmdd-HHMMSS>/`,
containing:

- `meta.json`: the traced sql, the enlisted relations and their oids, the clock window
  (`t_begin`/`t_end`), the git sha the capture was taken against, and a `producer` key naming
  which probe wrote the capture (`bench/lock_view.py` writes `ts` at the grant; the CI guard's
  own `bench/lock_probe.py` writes it at the request and carries no `producer` key at all, so a
  guard capture loaded here is never plotted as though its marks meant the same instant).
- `events.jsonl`: the raw capture (one JSON record per lock/commit event, plus a final
  `{"dropped": ..., "unmatched": ...}` tally).
- `names.before.csv` / `names.after.csv`: the relation-name snapshots taken immediately before
  and after the traced statement, each already carrying the SQL fold (index to its table,
  toast to its table, partition to its managed parent). A failed snapshot aborts the run rather
  than warning: `plot_lock_view.py`'s loader treats a missing or truncated CSV as "every
  relation was created during the window", which renders a wrong figure that still passes every
  refusal, so `bench/lock_view.sh` checks each snapshot's exit status and stops rather than
  hand that silently-wrong input to the renderer.
- `lock-view.png` and `lock-view.svg`: the rendered figure.

`bench/results/` is git-ignored (`bench/results/.gitignore`), so a run's output stays local by
default. To share one, force-add it explicitly:

```bash
git add -f bench/results/lockview-mytick-20260916-191847/
```

The container-side capture paths (`/tmp/pgpm_lock_view.jsonl`, `/tmp/pgpm_lock_view.log`) are
fixed, not per-run: two `lock_view.sh` invocations against the same container at the same time
will collide and corrupt each other's capture. Run one at a time per container.

### The four refusals

`bench/plot_lock_view.py` refuses to draw a capture it cannot trust, rather than render a
picture that looks fine and is wrong. Each refusal corresponds to a way that can happen:

| refusal | trips when | why a drawing would mislead |
| --- | --- | --- |
| `dropped` | the kernel ring buffer overflowed and the probe lost events | a truncated trace drawn as a complete one is the exact failure that made an earlier tracer unsound |
| `drain` | the probe was killed before it wrote its final tally | "dropped" is then unknown, and treating unknown as zero is the same mistake as above |
| `empty` | the capture recorded no lock events at all | an empty timeline and "the probe attached to nothing" render identically |
| `strong` | the capture never saw a strong-tier lock (`ShareRowExclusive`, `Exclusive` or `AccessExclusive`, per `tier()`) on any relation | a tick that did no real work renders as a calm, correct-looking figure of a no-op |

A run that trips one of these prints `refusing to draw this capture -- <refusal>: <detail>` on
stderr and exits nonzero instead of writing a figure. Passing `--modes strong` to
`plot_lock_view.py` filters which marks get drawn (dropping `AccessShare`); it does not affect
which captures are trusted enough to draw in the first place.

`unmatched` (a lock request that never got a matching grant, most often an aborted wait under
`lock_timeout`) is reported alongside `dropped` on the figure's footer but is deliberately **not**
a fifth refusal: it means the trace is complete and accurately reporting a wait it could not see
the end of, not that the trace is untrustworthy. See the design spec's "Requests, grants and
waits" section for the reasoning.

### The request/return pairing proof

`bench/lock_timeout_pairing_demo.sh` is a runnable, two-session demonstration of a defect that
was found and fixed in `bench/lock_view.py`'s eBPF probe: an aborted wait under `lock_timeout`
must be paired with and counted against its own request, never left to be silently stolen and
misreported by whatever `LockRelationOid` return comes next. See its own header for what it
demonstrates and how to run it.

It is also a guard, and the only one that covers that defect. `./test.sh lockview` runs it as its
second step, and `.github/workflows/lockview.yml` runs that track on every PR touching a lock-view
file (issue #398). It had to grow assertions to do that, because a demo that only prints what a
reader should look for cannot fail, and a check that cannot fail gates nothing. Its six checks are
four observations plus two liveness witnesses, and the witnesses are not decoration: every other
assertion it makes is a negative, so a run in which session A never acquired the lock would satisfy
all of them while proving nothing at all.

Measured against a probe with the fix hand-reverted, exactly as its header describes: two lock
events instead of one, a fabricated `wait_ns` of 100541273 against a 100 ms `lock_timeout`, and
`unmatched` 0 instead of 1. Three of the six checks flip, and both liveness witnesses stay green, so
the failure is attributable to the defect rather than to a fixture that quietly did nothing.
