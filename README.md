# pg_partition_magician

A lightweight, **pure-SQL** time-range partition manager for PostgreSQL whose only
runtime dependency is **pg_cron** — and even that only for scheduling. No compiled
extension, no superuser beyond what running a SQL script needs. Install it by
running one file.

It manages the full lifecycle of native `RANGE`-partitioned tables:

- **`adopt()`** — convert an existing (possibly huge, *live*) unpartitioned table
  into a partitioned one **online**, with no up-front data movement.
- **premake** — keep N partitions ahead of the write frontier so live writes
  always have a real partition.
- **drain** — move the `DEFAULT` partition's closed tail into proper partitions in
  paced microbatches.
- **retention** — drop partitions older than a policy.
- **maintenance** — the single procedure `pg_cron` calls (premake + retention + drain).

Think "a slice of `pg_partman`, installable as plain SQL." The schema is `pgpm`.

> Born from the design doc in
> [`postgresql_online_partition_migration_summary.md`](./postgresql_online_partition_migration_summary.md)
> and the locking analysis that followed.

## Why it exists

`pg_partman` is excellent, but it's a compiled C extension: it needs `CREATE
EXTENSION`, the binary installed, and privileges that some managed/locked-down
Postgres environments don't grant. `pg_partition_magician` is just tables, views,
and PL/pgSQL — you can install it anywhere you can run SQL and schedule a job.

## Install

```bash
psql "$DATABASE_URL" -f sql/pg_partition_magician.sql
```

Pure SQL, idempotent. (In this repo the same file is also applied as a Supabase
migration — `supabase/migrations/*_install_pg_partition_magician.sql` is a copy of
`sql/pg_partition_magician.sql`, the single source of truth.)

## Use it

```sql
-- Convert an existing table online and register it (zero data movement here):
select pgpm.adopt(
  p_parent      => 'public.events',
  p_control     => 'created_at',     -- the timestamp to range-partition on
  p_interval    => '1 day',          -- daily/weekly/monthly/yearly...
  p_premake     => 7,                -- keep 7 partitions ahead
  p_retention   => '90 days',        -- drop partitions older than this (null = keep)
  p_paused      => false             -- let scheduled maintenance run
);

-- Schedule the one entry point (pg_cron):
select cron.schedule('pgpm', '1 minute', 'call pgpm.maintenance_all()');
```

That's it. Maintenance premakes ahead, drains the adopted table's closed tail into
partitions, and applies retention. Watch it with `select * from pgpm.status();`.

### API

| Function | Purpose |
|---|---|
| `pgpm.adopt(parent, control, interval, …)` | Online swap + register + initial premake |
| `pgpm.maintenance_all()` | Premake + retention + one drain batch for every managed table (the pg_cron entry) |
| `pgpm.maintenance(parent)` | Same, for one table (respects the pause flag) |
| `pgpm.premake(parent)` | Create partitions up to `premake` ahead of now |
| `pgpm.drain_step(parent, batch, include_open)` | Move one microbatch out of the DEFAULT; attach when an interval empties |
| `pgpm.drain_all(parent, batch, include_open)` | Drive the drain to completion (ignores pause) |
| `pgpm.retention(parent)` | Drop partitions older than the policy |
| `pgpm.check_default(parent)` | Rows still in the DEFAULT, and how many are in already-closed intervals (the alert) |
| `pgpm.status()` / `pgpm.partitions` | Monitoring |

Config lives in `pgpm.config` (one row per managed table); a partition registry in
`pgpm.part`; an action audit trail in `pgpm.log`.

## How the online migration stays online

Two hard facts drive the design:

1. **You can't convert a table to partitioned in place.** So `adopt()` renames the
   live table out of the way, creates a partitioned parent under the original name,
   and **attaches the old table as the `DEFAULT` partition** — no rows move, the app
   sees no change. The PK is rebuilt to include the partition key *without rebuilding
   the index on the default*: the existing index is promoted to the default's PK and
   the parent's PK reuses it (metadata only — creating the parent *with* a PK and
   then attaching would instead rebuild that index on the whole default under
   `ACCESS EXCLUSIVE`). Identity moves to the parent; non-unique secondary indexes
   are carried over by attaching the default's existing index.
2. **Adding a partition while the `DEFAULT` holds data forces a full scan of the
   `DEFAULT` under `ACCESS EXCLUSIVE`** (PG 15 docs) — the biggest scaling risk.

The tool sidesteps #2 for every range that receives **no concurrent writes** —
closed past intervals (drain) and future intervals (premake) — by:

```
ADD CONSTRAINT excl CHECK (control < lo OR control >= hi) NOT VALID  -- catalog only, instant
VALIDATE CONSTRAINT excl                                            -- the scan, under SHARE UPDATE EXCLUSIVE (non-blocking)
ATTACH / CREATE PARTITION ...                                       -- default scan skipped, metadata-only
DROP CONSTRAINT excl
```

The one rule that keeps this safe: **never exclude the interval currently receiving
writes.** A `NOT VALID` CHECK is enforced on new rows, so excluding the live range
would *reject* writes routing to the default. So the active interval simply lives in
the `DEFAULT` until it closes, then drains as a closed tail — and premake keeps
future intervals ready so live writes always have a real partition. *The only window
we ever drain is the now-closed tail.*

Measured on PG 15 (4M-row default): plain attach **101 ms** under `ACCESS EXCLUSIVE`
vs scan-skip attach **0.43 ms**; the ~97 ms scan moves to `VALIDATE` under the
non-blocking lock. Same for `CREATE … PARTITION OF` premake (108 ms → 2 ms).

For the open/current interval there's no non-blocking option (a `NOT VALID` CHECK
would reject live writes), so it attaches via a **plain** `ATTACH` — which *blocks*
briefly rather than *rejecting*. Cheapest when it's drained last, against a small
default. Force it with `drain_all(parent, include_open => true)`.

## Demo (this repo)

The Supabase stack seeds a ~50k-row unpartitioned `public.messages` table across the
last 6 months, then `adopt()`s it.

```bash
supabase start
supabase db reset     # seed -> install pgpm -> adopt messages (maintenance PAUSED)
```

After reset: `messages` is `RANGE(created_at)`-partitioned, `messages_default` holds
all 50k rows, the next 4 months are premade, and a paused `pgpm-maintenance` cron job
exists. Drive it:

```sql
-- live (pg_cron, every 30s):
update pgpm.config set paused = false;
select * from pgpm.status();
select * from pgpm.check_default('public.messages');

-- or synchronous, finishing the current month too:
select pgpm.drain_all('public.messages', p_include_open => true);
```

Pinned to **PostgreSQL 15** (`supabase/config.toml`) — the realistic older-but-still-
supported workhorse (PG 14 leaves long-term support in late 2025); behavior is
identical on 15–17.

Scale the seed: `alter database postgres set poc.seed_count = 1000000;` then
`supabase db reset`.

## Tests

pgTAP, run against a freshly reset DB:

```bash
supabase db reset && supabase test db
```

23 tests across structure, write-routing, drain, row conservation, the scan-skip
attach method, premake, and retention.

> Reset before testing: tests assume the pristine post-reset state (data in the
> DEFAULT, maintenance paused). A live drain mutates committed state.

## v1 scope & caveats

- **Time `RANGE` only**, with a configurable interval (whole-month intervals like
  `1 month`/`1 year`, or fixed durations like `1 day`/`7 days`/`1 hour`). Mixed
  month+duration intervals are rejected. No integer/id range yet.
- **Empty `DEFAULT` kept as a safety net** (`keep_default`). In steady state premake
  stays ahead so the default stays empty; `check_default()` flags any stray row.
- **Retention uses plain `DROP`** (brief lock). `DETACH … CONCURRENTLY` can't run
  inside a function; for huge cold partitions, detach concurrently by hand.
- **Secondary indexes**: `adopt()` copies the old table's non-unique secondary
  indexes onto the parent as partitioned indexes (attaching the default's existing
  index, no rebuild), so they propagate to every partition. Unique secondary indexes
  are skipped (a partitioned unique index must include the partition key) — recreate
  those on the parent by hand.
- **Incoming foreign keys** — see the dedicated section below; `adopt()` refuses by
  default and offers an opt-in drop.
- Boundaries align to the database timezone (UTC on Supabase).

## Incoming foreign keys

If other tables reference the table you're adopting (e.g. `reactions(message_id) →
messages(id)`), partitioning forces a hard reckoning, because a partitioned table's
**only** unique key is one that includes the partition key:

- A single-column FK like `→ messages(id)` becomes **impossible** — *"there is no
  unique constraint matching given keys"* — and the old PK can't even be dropped
  while a dependent FK exists.
- The only way to keep DB-enforced RI is a **composite FK**: the referencing table
  must also carry `created_at` and reference `messages(created_at, id)`. (A composite
  FK to the *parent* survives the drain — a row keeps its `(created_at, id)` as it
  moves between partitions.)

So there's no "move the FK" trick; FKs can only be dropped and recreated, and
recreating requires denormalizing the partition key into the referencing side. This
is the operator's data-model decision, so `adopt()` doesn't do it silently:

- **Default (`p_incoming_fks => 'error'`)**: detects incoming FKs and **refuses**
  with a report, mutating nothing.
- **`p_incoming_fks => 'drop'`**: drops each incoming FK and records its original
  definition in `pgpm.dropped_fk`, then proceeds. You then either re-enforce RI in
  the app, or rebuild composite FKs after denormalizing the referencing tables.

```sql
select pgpm.adopt('public.messages', 'created_at', '1 month', p_incoming_fks => 'drop');
select * from pgpm.dropped_fk;   -- what was dropped, for reconstruction
```

(`pg_partman` reaches the same conclusion — its howto says incoming FKs require an
outage to drop and recreate against the new partitioned table.)

## Teardown

```bash
supabase stop
```
