# Online `messages` Partition Migration — POC

A runnable proof-of-concept for converting a large, unpartitioned PostgreSQL
`messages` table into a time-`RANGE`-partitioned table **with no up-front data
movement**, by attaching the existing table as the `DEFAULT` partition and then
**draining** historical rows into proper monthly partitions in paced microbatches
driven by **pg_cron**.

It implements the strategy described in
[`postgresql_online_partition_migration_summary.md`](./postgresql_online_partition_migration_summary.md)
and is built on the Supabase local dev stack with pgTAP tests.

## The idea in one paragraph

You cannot convert a table to partitioned in place. So you rename the live table
out of the way, create a partitioned parent under the original name, and attach
the old table as the `DEFAULT` partition — **no rows move**, the app sees no
change. New future-dated writes route to proper partitions immediately. A
background job then drains the `DEFAULT` partition month-by-month into proper
partitions, a few thousand rows per batch, slow enough that autovacuum keeps dead
tuples under control. Progress is fully observable, and the drain can be paused or
throttled at any time. The migration becomes a well-behaved maintenance workload
rather than a high-risk data-movement event.

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) (tested with 2.105)
- Docker (running)

## Quickstart

```bash
supabase start          # first run pulls images
supabase db reset       # applies migrations + seeds ~50k rows, then converts
```

After `db reset` you have:

- `public.messages` — a `RANGE(created_at)` partitioned table (PK `(created_at, id)`)
- `public.messages_default` — the `DEFAULT` partition, holding **all** seeded rows
- `messages_<next two months>` — empty, pre-created future partitions
- 6 month-windows queued in `partition_migration.windows` (state `pending`)
- a paused pg_cron job `drain-messages` (every 10s)

## Run the drain (pg_cron)

The drain is **paused by default** so `db reset` doesn't kick off background work
and so tests stay deterministic. Start it by flipping the control flag:

```sql
-- start the live drain (pg_cron fires every 10s, newest month first)
update partition_migration.control set is_paused = false;

-- throttle: smaller batches = gentler on vacuum/WAL/replication
update partition_migration.control set batch_size = 2000;

-- pause at any time
update partition_migration.control set is_paused = true;
```

Watch it progress:

```sql
-- per-window: how much is left in DEFAULT, what's been moved, current state
select * from partition_migration.progress;

-- storage/vacuum health of the DEFAULT partition during the drain
select * from partition_migration.health;
```

You'll see `rows_remaining_in_default` fall, windows move `pending → draining →
attached`, and `n_dead_tup` rise and fall as autovacuum reclaims space — the whole
point of the design.

Connect with `psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')"`
or just `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres`.

### Run it synchronously instead

For a one-shot full drain (used by the tests; ignores the pause flag):

```sql
select partition_migration.drain_all();   -- returns number of batches run
```

## Tests

pgTAP tests assert structure, write-routing, the full drain, and row-count
conservation. Run them against a freshly reset DB:

```bash
supabase db reset && supabase test db
```

> Run `supabase db reset` first. The tests assume the pristine post-reset state
> (all rows in `DEFAULT`, drain paused). If you've run a live drain, the committed
> state has changed — reset before testing.

## Scaling the seed

Default is ~50k rows. To stress the bloat/vacuum/observability behavior, scale up
without editing any file:

```sql
alter database postgres set poc.seed_count = 1000000;
```
```bash
supabase db reset
```

## How it maps to migrations

| File | Role |
|------|------|
| `…01_create_messages_unpartitioned.sql` | Legacy unpartitioned table + deterministic data generator |
| `…02_seed_legacy_data.sql` | Seed the table **before** conversion (parameterized by `poc.seed_count`) |
| `…03_convert_to_partitioned.sql` | Rename → build composite unique index → create partitioned parent → attach `DEFAULT` → pre-create future partitions |
| `…04_migration_control_and_drain.sql` | `partition_migration` schema: control + windows tables, `drain_step` (cron), `drain_all` (sync), `bootstrap_windows` |
| `…05_autovacuum_tuning.sql` | Aggressive per-table autovacuum on `messages_default` |
| `…06_observability_views.sql` | `progress` and `health` views |
| `…07_schedule_pg_cron.sql` | Create `pg_cron` extension and schedule the (paused) drain |

## POC vs. production caveats

This POC is deliberately honest about the parts the summary glosses over:

- **PK must include the partition key.** The enforced PK becomes `(created_at,
  id)`; uniqueness of `id` alone is no longer DB-enforced. Check your FKs and app
  assumptions.
- **You cannot attach a partition for a range that still has rows in `DEFAULT`.**
  That's why historical data is moved into a *standalone* staging table (with a
  matching `CHECK`) and only then `ATTACH`ed — not "moved into an already-attached
  partition."
- **`ATTACH` briefly scans + `ACCESS EXCLUSIVE`-locks `DEFAULT`** to prove no rows
  belong in the new range. The `CHECK` on the staging table avoids scanning *it*,
  but the `DEFAULT` scan is the real locking cost at scale.
- **Index builds.** This POC uses non-concurrent `CREATE [UNIQUE] INDEX` (fine at
  50k). In production build them with `CREATE [UNIQUE] INDEX CONCURRENTLY` outside
  a transaction.
- **Concurrent writes into the month currently being drained** are a documented
  minor race, out of scope for the deterministic test path.
- **pg_cron**: preloaded locally in the Supabase Postgres image; on hosted
  Supabase enable it via the dashboard first. If unavailable, the migration
  degrades gracefully — use `select partition_migration.drain_all();`.
- **pg_partman** is the production-grade tool for partition automation; this POC
  is hand-rolled to expose the mechanics.

## Teardown

```bash
supabase stop
```
