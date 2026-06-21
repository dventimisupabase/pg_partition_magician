# pg_partition_magician: user guide

A task-oriented guide to converting a live PostgreSQL table to native `RANGE` partitioning and
running it. For the full function/catalog reference see [reference.md](reference.md); for the design
rationale see [DESIGN.md](../DESIGN.md); for a visual overview see the
[explainer](https://dventimisupabase.github.io/pg_partition_magician/).

## Contents

- [Concepts](#concepts)
- [Install](#install)
- [Adopt a table](#adopt-a-table)
- [Run it](#run-it)
- [Monitor](#monitor)
- [Retention](#retention)
- [Incoming foreign keys](#incoming-foreign-keys)
- [Secondary indexes](#secondary-indexes)
- [How the conversion stays online](#how-the-conversion-stays-online)
- [Operations and troubleshooting](#operations-and-troubleshooting)
- [Caveats and v1 scope](#caveats-and-v1-scope)

## Concepts

**What it manages.** pg_partition_magician adopts an existing, unpartitioned table into a native
`RANGE`-partitioned table and then keeps it healthy: it creates future partitions ahead of your
writes, moves old rows out of a holding area into their proper partitions in small steps, and drops
partitions past your retention policy. Everything is pure SQL in the `pgpm` schema; the only runtime
dependency is `pg_cron`, and only to run the background job.

**Control kinds.** A table is partitioned on one monotonic key, of one of three kinds:

- `time`: a `timestamptz` / `timestamp` / `date` column, on an interval grid (calendar-aligned for
  whole months/years, fixed-duration otherwise). Adopt with `pgpm.adopt`.
- `id`: an `int` / `bigint` / `numeric` column, on an integer step. Covers Snowflake-style ids.
  Adopt with `pgpm.adopt_by_id`.
- `uuidv7`: a `uuid` column holding time-ordered UUIDv7 (or ULID-as-uuid) values, on a time grid
  with uuid-encoded bounds. Adopt with `pgpm.adopt_by_uuidv7`.

`float` / `double` are rejected: they cannot guarantee gapless boundaries and `NaN`/`Inf` poison the
ordering. Other sortable encodings (KSUID, base32 ULID, ObjectId) are not built in; partition on a
companion column instead.

**The frontier.** The frontier is the newest point the data has reached: `now()` for `time`, and
`max(control)` for `id` and `uuidv7`. An interval is "open" while the frontier is inside it (it is
still receiving writes) and "closed" once the frontier moves past its upper bound.

**The DEFAULT is a safety net.** Adoption attaches your original table as the `DEFAULT` partition, so
any row that does not match a real partition still has a home (no lost writes, ever). In steady state
premake keeps the current and future intervals covered, so the DEFAULT holds only the open interval
and otherwise stays empty. `check_default()` tells you if anything is stuck there.

**The lifecycle (what maintenance does).** One scheduled procedure, `pgpm.maintenance_all()`, drives
three jobs per table:

- **premake**: create up to N partitions ahead of the frontier, so live writes always land in a real
  partition.
- **drain**: move the DEFAULT's closed tail into proper partitions, a small microbatch at a time,
  then attach each interval's partition when it empties. The only range ever drained is one that has
  closed (no contention with live writes).
- **retention**: drop partitions older than your policy.

## Install

`sql/pg_partition_magician.sql` is the single source of truth: pure, idempotent SQL with no psql
metacommands. It ships through three channels, all built from that one file.

The simplest path, on any Postgres you can run SQL against:

```bash
psql "$DATABASE_URL" -f sql/pg_partition_magician.sql
```

For a SQL client that does not process psql metacommands (a dashboard editor, say), build a
self-contained `BEGIN/COMMIT`-wrapped bundle and paste it in:

```bash
scripts/build_install_bundle.sh sql/pg_partition_magician.sql dist/pg_partition_magician-bundle.sql
```

On a managed Postgres with `pg_tle`, it can also be installed as a Trusted Language Extension from
[database.dev](https://database.dev) (the `psql -f` path above is simpler and recommended):

```sql
select dbdev.install('dventimisupabase@pg_partition_magician');
create extension "dventimisupabase@pg_partition_magician" version '0.1.0' cascade;
```

You also need `pg_cron` enabled to run scheduled maintenance.

**Uninstall** removes the `pgpm` schema and its cron jobs; your partitioned tables and data are left
intact:

```bash
psql "$DATABASE_URL" -f sql/uninstall.sql
```

## Adopt a table

Adoption is online and moves no data up front: it renames your table to `<name>_default`, creates a
partitioned parent under the original name, and attaches the old table as the `DEFAULT` partition.

### Pick the kind

```sql
-- time
select pgpm.adopt('public.events', 'created_at', '1 month');

-- id (bigint/numeric), 10M ids per partition
select pgpm.adopt_by_id('public.events', 'id', 10000000);

-- uuidv7 / ULID-as-uuid
select pgpm.adopt_by_uuidv7('public.events', 'id', '1 day');
```

Adoption registers the table **paused** by default: it is converted, but scheduled maintenance does
nothing until you unpause (see [Run it](#run-it)). All parameters are documented in the
[reference](reference.md#adoption).

### Keep the cutover online: build the PK first

Adoption must widen the primary key to include the partition key (e.g. `(created_at, id)`). How that
index is built decides whether the cutover is truly online:

- **Recommended on a large table:** build the index online first, then adopt.

  ```sql
  call pgpm.build_pk_concurrently('public.events', 'created_at');
  select pgpm.adopt('public.events', 'created_at', '1 month');
  ```

  `build_pk_concurrently` issues a `CREATE UNIQUE INDEX CONCURRENTLY` through a `pg_cron` worker (no
  blocking) and waits for it to finish. `adopt` then promotes that ready index, so it holds its
  `ACCESS EXCLUSIVE` lock only briefly (metadata-only).

- **Fallback:** if no matching index exists, `adopt` builds it in-transaction under
  `ACCESS EXCLUSIVE`. Correct, but `O(rows)`: roughly a 28-minute write-blocking window at 300M rows.
  Fine for small tables only.

When the `id` key is already the table's single-column primary key, the partition key already covers
it, so adopt reuses the existing index in place and the build cost disappears entirely.

## Run it

Schedule the single entry point with `pg_cron`, then unpause:

```sql
select cron.schedule('pgpm', '1 minute', 'call pgpm.maintenance_all()');
update pgpm.config set paused = false where parent_table = 'public.events'::regclass;
```

From there, each tick premakes ahead, drains a microbatch of the closed tail, and applies retention.
You can also adopt with `p_paused => false` to skip the manual unpause.

To convert a table synchronously (tests, one-shot migrations) instead of waiting for the paced cron,
drive the drain to completion yourself. `p_include_open => true` also drains and attaches the current
open interval (a brief blocking attach against a small default):

```sql
select pgpm.drain_all('public.events', p_include_open => true);
```

Tune the pace with `config.drain_batch` (rows per microbatch) and the cron cadence. For tables with
highly variable row width, set `config.drain_max_blocks` to cap each batch by storage size rather
than row count.

## Monitor

```sql
select * from pgpm.status();        -- one row per managed table: partitions, rows still in DEFAULT
select * from pgpm.partitions;      -- the partition registry with bounds
```

The key health signal is the DEFAULT's closed tail. In steady state it should be zero:

```sql
select * from pgpm.check_default('public.events');
```

`closed_rows > 0` means rows that should have drained are still in the DEFAULT (the drain is behind,
or paused). `default_rows` counting only the open interval is normal.

For `uuidv7` tables, confirm the column really is time-ordered (not random UUIDv4):

```sql
select * from pgpm.check_uuidv7('public.events', 'id');
```

A low `fraction` means the values do not decode to plausible timestamps and the table should not be
partitioned on that column. For an `id`-partitioned table where you want calendar retention, check
that a timestamp column rises with the id:

```sql
select * from pgpm.check_time_monotonic('public.events', 'id', 'created_at');
```

## Retention

Set a policy at adopt time (`p_retention`) or later via `config.retention`, and maintenance drops
partitions past it. Retention is an interval for `time`/`uuidv7` and a count of intervals for `id`.
`null` keeps everything.

```sql
update pgpm.config set retention = '90 days' where parent_table = 'public.events'::regclass;
```

Retention uses plain `DROP` (a brief lock). `DETACH ... CONCURRENTLY` cannot run inside a function,
so for very large cold partitions you may prefer to detach them concurrently by hand.

## Incoming foreign keys

If other tables reference the table you are adopting (e.g. `reactions(message_id) -> messages(id)`),
what partitioning does to that FK depends on whether you partition on the same column the FK
references. The governing rule: a unique or primary key on a partitioned table must include every
partition-key column.

### When the partition key already is the referenced key (id / uuidv7)

If you adopt on the table's own single-column primary key (the `adopt_by_id` / `adopt_by_uuidv7`
happy path, where the partition key equals the PK), that single-column PK is legal on the partitioned
parent, because its columns already include the partition key. The incoming FK stays valid against
the new parent's `id`: no composite key, no denormalization.

There is one mechanical wrinkle. The drain moves the closed tail through a standalone, not-yet-attached
child table, so a referenced row is briefly outside the parent while it is moved, which a `NO ACTION`
FK rejects. The FK therefore cannot ride through the conversion in place. The clean path today is:
drop and record the FK at adopt (the `'drop'` mode below), let the drain finish, then re-add the same
single-column FK against the new parent (`NOT VALID` + `VALIDATE`); the referencing table is untouched.
Automating this is a planned feature (see DESIGN.md section 8).

### When you partition on a different column (time)

If you partition on a column other than the referenced key (the typical `time` case: partition on
`created_at` while the FK references `id`), the PK must widen to include the partition key, e.g.
`(created_at, id)`. The single-column unique on `(id)` no longer exists, so:

- A single-column FK like `-> messages(id)` becomes impossible (`there is no unique constraint
  matching given keys`), and the old PK cannot even be dropped while a dependent FK exists.
- The only way to keep database-enforced referential integrity is a composite FK: the referencing
  table must also carry `created_at` and reference `messages(created_at, id)`. A composite FK to the
  parent survives the drain, because a row keeps its `(created_at, id)` as it moves between
  partitions.

### Adopt does not change your data model silently

Either way, `adopt` offers two modes for incoming FKs:

- **`p_incoming_fks => 'error'` (default):** detect incoming FKs and refuse, mutating nothing.
- **`p_incoming_fks => 'drop'`:** drop each incoming FK, record its original definition in
  `pgpm.dropped_fk`, then proceed. You then re-add the FK against the new parent (id / uuidv7 happy
  path), re-enforce integrity in the app, or rebuild composite FKs after denormalizing the
  referencing tables (time case).

```sql
select pgpm.adopt('public.messages', 'created_at', '1 month', p_incoming_fks => 'drop');
select * from pgpm.dropped_fk;   -- what was dropped, for reconstruction
```

For the widening (time) case, rebuild as composite FKs: `generate_fk_recovery` emits a
ready-to-review script per dropped FK that adds the partition-key companion column, backfills it, and
rebuilds the FK with `NOT VALID` + `VALIDATE` (to avoid a long lock). It is generated, not executed:

```sql
select sql from pgpm.generate_fk_recovery('public.messages');
```

```sql
-- e.g. for reactions(message_id) -> messages(id):
ALTER TABLE public.reactions ADD COLUMN message_created_at timestamp with time zone;
UPDATE public.reactions r SET message_created_at = p.created_at
  FROM public.messages p WHERE p.id = r.message_id;
ALTER TABLE public.reactions ALTER COLUMN message_created_at SET NOT NULL;
ALTER TABLE public.reactions ADD CONSTRAINT reactions_message_id_fkey
  FOREIGN KEY (message_created_at, message_id) REFERENCES public.messages (created_at, id) NOT VALID;
ALTER TABLE public.reactions VALIDATE CONSTRAINT reactions_message_id_fkey;
```

Review it (the companion column name is a suggestion; batch the backfill for large tables) and update
the app to populate the new column going forward. (`pg_partman` reaches the same conclusion: incoming
FKs require dropping and recreating against the new partitioned table.)

## Secondary indexes

`adopt` copies the old table's non-unique secondary indexes onto the parent as partitioned indexes
(attaching the default's existing index, no rebuild), so they propagate to every partition. Unique
secondary indexes are skipped, because a partitioned unique index must include the partition key;
recreate those on the parent by hand.

## How the conversion stays online

Two facts about Postgres drive the design:

1. You cannot convert a table to partitioned in place, so adopt renames the live table, creates a
   partitioned parent under the original name, and attaches the old table as the `DEFAULT`. No rows
   move; the app sees no change.
2. Adding a partition while the DEFAULT holds data forces a full scan of the DEFAULT under
   `ACCESS EXCLUSIVE`, which would block the workload.

pgpm sidesteps #2 for every range that receives no concurrent writes (closed past intervals on the
drain, future intervals on premake) with a scan-skip attach:

```sql
ADD CONSTRAINT excl CHECK (control < lo OR control >= hi) NOT VALID  -- catalog only, instant
VALIDATE CONSTRAINT excl                                            -- the scan, under SHARE UPDATE EXCLUSIVE (non-blocking)
ATTACH / CREATE PARTITION ...                                       -- default scan skipped, metadata-only
DROP CONSTRAINT excl
```

The one rule that keeps this safe: never exclude the interval currently receiving writes (a
`NOT VALID` CHECK is enforced on new rows, so excluding the live range would reject writes routing to
the DEFAULT). So the active interval simply lives in the DEFAULT until it closes, then drains as a
closed tail. Measured on PG 15 (4M-row default): plain attach 101 ms under `ACCESS EXCLUSIVE` vs
scan-skip attach 0.43 ms. The full rationale is in [DESIGN.md](../DESIGN.md).

## Operations and troubleshooting

- **Pause / unpause.** `update pgpm.config set paused = ... where parent_table = '...'::regclass;`.
  A paused table is registered but untouched by `maintenance` (you can still drive `drain_*`
  manually).
- **The closed tail is growing.** `check_default()` shows `closed_rows > 0`: the table is unpaused
  but the drain is not keeping up. Raise `drain_batch`, run the cron more often, or run
  `drain_all()` once to catch up.
- **Re-adopting a table fails with an "orphan" error.** A drain creates each child partition as a
  standalone table and attaches it only when that interval finishes draining. If a drain is
  interrupted and you then `DROP TABLE <parent> CASCADE` and recreate the table, the un-attached
  child survives the cascade (it has no dependency on the parent) and a re-adopt would collide on its
  stale keys. `adopt` detects this and refuses up front; drop the named orphan table and retry.
- **Finishing the current period.** Normal maintenance never drains the open interval. To convert a
  table completely (including the in-progress interval), run
  `drain_all(parent, p_include_open => true)`; the open interval attaches via a brief blocking
  attach, cheapest done last against a small default.

## Caveats and v1 scope

- **Dimensions:** `time` (interval step; whole-month or fixed-duration; mixing is rejected), `id`
  (bigint/numeric step), `uuidv7`/ULID-as-uuid (time grid, uuid bounds). `float`/`double` rejected.
  Other sortable encodings are not built in; partition on a companion column.
- **Monotonicity is the precondition.** UUIDv7/ULID are ms-resolution monotonic with a small
  clock-skew/late-arrival window; the don't-close-until-frontier-past rule plus the DEFAULT safety
  net absorb stragglers. Arbitrary backdated keys break it.
- **Empty DEFAULT kept as a safety net** (`keep_default`). In steady state premake stays ahead so the
  DEFAULT stays empty; `check_default()` flags any stray row.
- **Retention uses plain `DROP`** (a brief lock); detach huge cold partitions concurrently by hand.
- **Unique secondary indexes** are not auto-propagated (a partitioned unique index must include the
  partition key); recreate them on the parent by hand.
- **Incoming foreign keys** require dropping and recreating as composite FKs; see above.
- Tested on PostgreSQL **15, 16, 17, and 18**. Boundaries align to the database timezone (UTC by
  default).
