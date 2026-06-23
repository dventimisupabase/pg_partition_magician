# pg_partition_magician

**[→ Explainer &amp; install page](https://dventimisupabase.github.io/pg_partition_magician/)**

[![pg_partition_magician: partition a live Postgres table online](docs/screenshot.png)](https://dventimisupabase.github.io/pg_partition_magician/)

A lightweight, **pure-SQL** RANGE-partition manager for PostgreSQL whose only runtime dependency is
**pg_cron**, and even that only to run its background jobs. No compiled extension, no superuser
beyond what running a SQL script needs. Install it by running one file.

It partitions on three kinds of **monotonic** key: time, integer/bigint ids (including
Snowflake-style ids), or **UUIDv7 / ULID** (time-ordered uuids). It then manages the full lifecycle
of native `RANGE`-partitioned tables:

- **`transmute()`**: convert an existing (possibly huge, *live*) unpartitioned table into a partitioned
  one **online**, with no up-front data movement. One function, two type-safe overloads picked by the
  width parameter (an `interval` for the time grid, a `bigint` step for the integer grid); the kind
  (time vs uuidv7) is read from the control column's type. Reversible with **`untransmute()`** up until
  maintenance first runs: the cutover moves no data, so the table can be cleanly restored until a real
  partition exists (after that it is a one-way door).
- **attain**: keep N partitions ahead of the write frontier so live writes always have a real
  partition.
- **drain**: move the `DEFAULT` partition's closed tail into proper partitions in paced microbatches.
  Optionally adaptive (`pgpm.set_drain_adaptive`): the pace self-tunes against checkpoint pressure to
  stay unnoticeable.
- **retain**: drop partitions older than a policy.
- **maintenance**: the single procedure `pg_cron` calls (attain, drain, retain).

**Incoming foreign keys** are handled, not ignored. `transmute` never rewrites the primary key, so the
referenced unique key always survives partitioning: with `p_incoming_fks => 'preserve'` it records
and drops each incoming FK for the conversion, then re-adds it against the new parent once the drain
is idle (no composite-FK story, ever). A table whose primary key excludes the control column is
refused: partition on a key that is already part of your PK. See the
[guide](docs/guide.md#incoming-foreign-keys).

Think "a slice of `pg_partman`, installable as plain SQL." The schema is `pgpm`.

## Why it exists

`pg_partman` is excellent, but it is a compiled C extension: it needs `CREATE EXTENSION`, the binary
installed, and privileges that some managed or locked-down Postgres environments do not grant.
`pg_partition_magician` is just tables, views, and PL/pgSQL; you can install it anywhere you can run
SQL and schedule a job.

## Install

```bash
# the simplest path on any Postgres: run the single source file
psql "$DATABASE_URL" -f sql/pg_partition_magician.sql
```

Need copy-paste for a dashboard SQL editor, or the registry command? The
[install page](https://dventimisupabase.github.io/pg_partition_magician/install.html) has one-click
bundles and the dbdev command, and the [user guide](docs/guide.md#install) covers all three channels
and uninstall. `pg_cron` must be enabled to run scheduled maintenance.

## Quickstart

```sql
-- 1. Convert a live table online and register it (no data moves here):
select pgpm.transmute(
  p_parent   => 'public.events',
  p_control  => 'created_at',         -- the timestamp to range-partition on
  p_interval => interval '1 month',   -- daily / weekly / monthly / yearly ...
  p_attain   => 7,                    -- keep 7 partitions ahead
  p_retain   => '90 days',            -- drop partitions older than this (null = keep)
  p_paused   => false                 -- let scheduled maintenance run
);

-- 2. Schedule the one entry point (pg_cron):
select cron.schedule('pgpm', '1 minute', 'call pgpm.maintenance_all()');

-- 3. Watch it:
select * from pgpm.status();
```

That is it. Maintenance obtains new empty partitions ahead, drains the
transmuted table's closed tail into empty partitions, and applies
retention to keep or drop old partitions. `transmute` never rewrites
the primary key, so the cutover is always metadata-only; it just
requires the control column to already be part of the table's primary
key (else it refuses). See the [transmute
walkthrough](docs/guide.md#transmute-a-table).

## Documentation

- **[User guide](docs/guide.md)**: concepts, install, transmuting a table, scheduling, monitoring,
  retain, incoming foreign keys, operations and troubleshooting.
- **[Reference](docs/reference.md)**: every function and catalog object (signatures, parameters,
  returns, examples).
- **[Explainer](https://dventimisupabase.github.io/pg_partition_magician/)**: the visual overview of
  how the online conversion works.
- **[DESIGN.md](DESIGN.md)**: the operating model and design rationale.

## Tests

```bash
./test.sh            # full matrix: PG 15-18 x all install channels
./test.sh 15         # one version, all channels
```

The suite is pgTAP, runs on Docker only, and is exactly what CI runs on every push. See
[ONBOARDING.md](ONBOARDING.md) for the development loop and the test matrix in detail.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
