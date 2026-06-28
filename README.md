# pg_partition_magician

**[→ Explainer &amp; install page](https://dventimisupabase.github.io/pg_partition_magician/)**

[![pg_partition_magician: partition a live Postgres table online](docs/screenshot.png)](https://dventimisupabase.github.io/pg_partition_magician/)

A lightweight, **pure-SQL** RANGE-partition manager for PostgreSQL whose only runtime dependency is
**pg_cron**, and even that only to run its background job. No compiled extension, no superuser beyond
what running a SQL script needs. Install it by running one file.

It partitions on three kinds of **monotonic** key: time, integer/bigint ids (including Snowflake-style
ids), or **UUIDv7 / ULID** (time-ordered uuids). It then manages the full lifecycle of native
`RANGE`-partitioned tables:

- **`transmute()`**: convert an existing (possibly huge, *live*) unpartitioned table into a partitioned
  one **online, with no row movement**. The original is renamed aside and attached, intact, as one
  bounded **monolith** child holding the whole history; a fresh empty `DEFAULT` is the safety net. The
  cutover does one online, read-only scan, then a brief metadata-only step: no index rebuild, no
  downtime. One function, two type-safe overloads picked by the width parameter (an `interval` for the
  time grid, a `bigint` step for the integer grid). Reversible with **`untransmute()`** while the monolith
  still holds the whole table; once a row lands outside it (the frontier moves on) or you refine it, it is
  a one-way door.
- **obtain**: keep N partitions ahead of the write frontier so live writes always have a real partition.
- **`refine()`**: split the coarse monolith into proper, fine-grained partitions, on demand or paced
  across maintenance ticks (`pgpm.set_refine`). It **copies** rows into new partitions and swaps them in,
  so there are no dead tuples and no vacuum. This is the bulk mover, and it is **optional**: a coarse
  monolith is a correct, permanent state; refining is what restores partition pruning and fine-grained
  retention over the history.
- **drain** (the magician's assistant): keep the `DEFAULT` empty by evacuating the occasional stray into
  its proper partition. Optionally adaptive (`pgpm.set_drain_adaptive`): the pace self-tunes against
  checkpoint pressure to stay unnoticeable, and the same budget feathers `refine`.
- **retain**: drop partitions older than a policy (suspended over coarse history until it is refined).
- **maintain**: the single procedure `pg_cron` calls (obtain, drain, retain, and optional auto-refine).

One honest caveat: the scheduled assistant **drain** moves rows through an unattached child, so a mid-move
read of the parent **undercounts** the range in flight (and a write to an already-moved row no-ops) until
it attaches. **`refine` never opens this gap** (it copies, leaving every row in the monolith until one
atomic swap), and the synchronous `drain_all()` is gap-free too; `pgpm.snapshot` gives a complete read
while the paced drain is mid-move.
The [guide](docs/guide.md#read-consistency-during-a-move) explains it in full.

**Incoming foreign keys** are handled, not ignored. `transmute` never rewrites your key, so the
referenced unique key always survives partitioning: with `p_incoming_fks => 'preserve'` it records and
drops each incoming FK for the conversion, then re-adds it against the new parent once the move is idle (no
composite-FK story, ever). A table whose key excludes the control column is refused: partition on a key
(primary key or unique constraint) that already includes the control column. See the
[guide](docs/guide.md#incoming-foreign-keys).

Think "a slice of `pg_partman`, installable as plain SQL." The schema is `pgpm`.

## Why it exists

`pg_partman` is excellent, but it is a compiled C extension: it needs `CREATE EXTENSION`, the binary
installed, and privileges that some managed or locked-down Postgres environments do not grant.
`pg_partition_magician` is just tables, views, and PL/pgSQL; you can install it anywhere you can run SQL
and schedule a job.

## Install

```bash
# the simplest path on any Postgres: run the single source file
psql "$DATABASE_URL" -f pgpm_core/install.sql
```

Need copy-paste for a dashboard SQL editor, or the registry command? The
[install page](https://dventimisupabase.github.io/pg_partition_magician/install.html) has one-click
bundles and the dbdev command, and the [user guide](docs/guide.md#install) covers all three channels and
uninstall. `pg_cron` must be enabled to run scheduled maintenance.

## Quickstart

```sql
-- 1. Convert a live table online and register it. The cutover moves no rows (the history becomes one
--    bounded "monolith" partition), and the table registers PAUSED: nothing happens until you resume.
select pgpm.transmute(
  p_parent   => 'public.events',
  p_control  => 'created_at',         -- the timestamp to range-partition on (must be in the PK)
  p_interval => interval '1 month',   -- daily / weekly / monthly / yearly ...
  p_obtain   => 7,                    -- keep 7 partitions ahead
  p_retain   => '90 days'             -- drop partitions older than this (null = keep)
);

-- 2. Schedule maintenance on pg_cron (one job covers every table; idle while paused):
select pgpm.schedule();   -- every minute; pass a pg_cron schedule (e.g. '*/5 * * * *') for another cadence

-- 3. Inspect, then go live. Maintenance obtains partitions ahead and keeps the DEFAULT empty:
select * from pgpm.status();
select pgpm.resume('public.events');

-- 4. (optional) Split the coarse history into fine partitions, paced across ticks:
select pgpm.set_refine('public.events', '1 month');
```

That is it. The conversion is a deliberate two-step: `transmute` registers the table paused so you can
inspect it, and maintenance does nothing until you `resume`. Once live, it keeps real partitions ahead of
the frontier and the `DEFAULT` empty; the historical bulk stays in the monolith until you choose to
`refine` it (by hand or via auto-refine). `transmute` never rewrites your key: it reuses a primary key or
unique constraint that includes the control column, or partitions the table keyless if it has neither. The
one requirement is a `NOT NULL` control column. See the [transmute walkthrough](docs/guide.md#transmute-a-table).

## Migrating from TimescaleDB

Coming from a **TimescaleDB hypertable** (Apache edition)? `from_hypertable` migrates one to a pgpm-managed
native partition set: it copies the hypertable into a plain table online (the source keeps serving traffic),
then hands off to `transmute`. The copy preserves your keys, secondary indexes, identity columns (with their
exact sequence position), generated columns, CHECK constraints, defaults, and NOT NULL, and a `drop_chunks`
retention policy is carried into pgpm `retain`. Only the brief cutover takes a lock. Keyed and keyless
hypertables are both supported. Append workloads catch up automatically; for workloads that update or delete
rows during the copy, pass `p_track_changes => true` to capture those changes.

```sql
-- one shot: copy online, then cut over and hand off to transmute
call pgpm.from_hypertable('public.metrics', 'ts', interval '1 day');
```

It is an optional add-on, loaded only where the `timescaledb` extension exists, so pgpm's core stays
dependency-free:

```bash
psql "$DATABASE_URL" -f pgpm_hypertable/install.sql
```

See the [reference](docs/reference.md#migrating-from-timescaledb-from_hypertable) for the phases,
`p_track_changes`, and the disk estimate.

## Documentation

- **[User guide](docs/guide.md)**: concepts, install, transmuting a table, scheduling, refine, monitoring,
  retain, incoming foreign keys, operations and troubleshooting.
- **[Reference](docs/reference.md)**: every function and catalog object (signatures, parameters, returns,
  examples).
- **[Runbook](docs/runbook.md)**: symptom-driven, step-by-step operational procedures for when an alert
  fires.
- **[Explainer](https://dventimisupabase.github.io/pg_partition_magician/)**: the visual overview of how
  the online conversion works.
- **[REDESIGN.md](REDESIGN.md)**: the operating model and design rationale (the bounded-child transmute).

## Tests

```bash
./test.sh            # full matrix: PG 15-18 x all install channels
./test.sh 15         # one version, all channels
```

The suite is pgTAP, runs on Docker only, and is exactly what CI runs on every push. See
[ONBOARDING.md](ONBOARDING.md) for the development loop and the test matrix in detail.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
