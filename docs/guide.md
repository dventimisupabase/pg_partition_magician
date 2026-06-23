# pg_partition_magician: user guide

A task-oriented guide to converting a live PostgreSQL table to native `RANGE` partitioning and
running it. For the full function/catalog reference see [reference.md](reference.md); for the design
rationale see [DESIGN.md](../DESIGN.md); for a visual overview see the
[explainer](https://dventimisupabase.github.io/pg_partition_magician/).

## Contents

- [Concepts](#concepts)
- [Install](#install)
- [Transmute a table](#transmute-a-table)
- [Run it](#run-it)
- [Monitor](#monitor)
- [Retain](#retain)
- [Incoming foreign keys](#incoming-foreign-keys)
- [Secondary indexes](#secondary-indexes)
- [How the conversion stays online](#how-the-conversion-stays-online)
- [WAL and checkpoint sizing](#wal-and-checkpoint-sizing)
- [Operations and troubleshooting](#operations-and-troubleshooting)
- [Caveats and v1 scope](#caveats-and-v1-scope)

## Concepts

**What it manages.** pg_partition_magician transmutes an existing, unpartitioned table into a native
`RANGE`-partitioned table and then keeps it healthy: it creates future partitions ahead of your
writes, moves old rows out of a holding area into their proper partitions in small steps, and drops
partitions past your retention policy. Everything is pure SQL in the `pgpm` schema; the only runtime
dependency is `pg_cron`, and only to run the background job.

**Control kinds.** A table is partitioned on one monotonic key, of one of three kinds:

- `time`: a `timestamptz` / `timestamp` / `date` column, on an interval grid (calendar-aligned for
  whole months/years, fixed-duration otherwise). Transmute with `pgpm.transmute(..., interval '...')`.
- `id`: an `int` / `bigint` / `numeric` column, on an integer step. Covers Snowflake-style ids.
  Transmute with `pgpm.transmute(..., <bigint step>)`.
- `uuidv7`: a `uuid` column holding time-ordered UUIDv7 (or ULID-as-uuid) values, on a time grid
  with uuid-encoded bounds. Transmute with `pgpm.transmute(..., interval '...')` (uuidv7 is inferred from the
  uuid column).

`float` / `double` are rejected: they cannot guarantee gapless boundaries and `NaN`/`Inf` poison the
ordering. Other sortable encodings (KSUID, base32 ULID, ObjectId) are not built in; partition on a
companion column instead.

**The frontier.** The frontier is the newest point the data has reached: `now()` for `time`, and
`max(control)` for `id` and `uuidv7`. An interval is "open" while the frontier is inside it (it is
still receiving writes) and "closed" once the frontier moves past its upper bound.

**The DEFAULT is a safety net.** Transmutation attaches your original table as the `DEFAULT` partition, so
any row that does not match a real partition still has a home (no lost writes, ever). In steady state
obtain keeps the current and future intervals covered, so the DEFAULT holds only the open interval
and otherwise stays empty. `check_default()` tells you if anything is stuck there.

**The lifecycle (what maintenance does).** One scheduled procedure, `pgpm.maintain_all()`, drives
three jobs per table:

- **obtain**: create up to N partitions ahead of the frontier, so live writes always land in a real
  partition.
- **drain**: move the DEFAULT's closed tail into proper partitions, a small microbatch at a time,
  then attach each interval's partition when it empties. The only range ever drained is one that has
  closed (no contention with live writes).
- **retain**: drop partitions older than your policy.

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

## Transmute a table

Transmutation is online and moves no data up front: it renames your table to `<name>_default`, creates a
partitioned parent under the original name, and attaches the old table as the `DEFAULT` partition.

### Pick the kind

There is one `pgpm.transmute`, with two type-safe overloads chosen by the width parameter: an `interval`
selects the time grid, a `bigint` step selects the integer grid. The kind (time vs uuidv7) is
auto-detected from the control column's type. A bare interval string literal is ambiguous between the
overloads, so interval calls must cast (`interval '...'`); an integer width needs no cast.

```sql
-- time (timestamp/timestamptz/date control column)
select pgpm.transmute('public.events', 'created_at', interval '1 month');

-- id (bigint/numeric), 10M ids per partition
select pgpm.transmute('public.events', 'id', 10000000);

-- uuidv7 / ULID-as-uuid (uuid control column; inferred from the column type)
select pgpm.transmute('public.events', 'id', interval '1 day');
```

Transmutation registers the table **paused** by default: it is converted, but scheduled maintenance does
nothing until you `resume` it (see [Run it](#run-it)). All parameters are documented in the
[reference](reference.md#transmutation).

### The cutover is always metadata-only

`transmute` never rewrites the primary key. It reuses the existing PK in place, so the cutover holds its
`ACCESS EXCLUSIVE` lock only briefly (no `O(rows)` index build, ever).

The one requirement is that the control column already be part of the primary key. Postgres only
requires a partitioned PK to *include* the partition key, not lead it, so a single-column PK on the
control column qualifies, and so does a composite PK that contains it (e.g. `(tenant_id, id)`
partitioned by `id`). A table with no primary key at all is fine too.

If the table has a PK that *excludes* the control column (the classic `events(id PRIMARY KEY,
created_at)` wanting time partitioning), `transmute` refuses with a clear error: make the control column
part of the PK first, then re-transmute. Either give the table a single-column time-ordered key, or widen
the PK yourself (`CREATE UNIQUE INDEX CONCURRENTLY`, then `ALTER TABLE ... ADD PRIMARY KEY USING
INDEX`). pgpm only partitions tables whose key is already the partition key: the modern
time-ordered-PK data model (bigint/Snowflake, UUIDv7, ULID).

## Run it

Schedule the single entry point with `pg_cron`. It stays idle while the table is paused, so inspect
with [`status()`](#monitor) first, then `resume` to go live:

```sql
select cron.schedule('pgpm', '1 minute', 'call pgpm.maintain_all()');
select * from pgpm.status();              -- looks right?
select pgpm.resume('public.events');      -- go live
```

From there, each tick obtains ahead, drains a microbatch of the closed tail, and applies retention.
You can also transmute with `p_paused => false` to go live immediately and skip the `resume` step.

To convert a table synchronously (tests, one-shot migrations) instead of waiting for the paced cron,
drive the drain to completion yourself. `p_include_open => true` also drains and attaches the current
open interval (a brief blocking attach against a small default):

```sql
select pgpm.drain_all('public.events', p_include_open => true);
```

Tune the pace with `config.drain_batch` (rows per microbatch) and the cron cadence. For tables with
highly variable row width, set `config.drain_max_blocks` to cap each batch by storage size rather
than row count.

### Adaptive feathering (let the drain tune itself)

Instead of fixing the rate by hand, turn on adaptive mode and let pgpm ride the drain just under the
system's spare capacity:

```sql
select pgpm.set_drain_adaptive('public.events', true);
```

Or choose it up front at conversion time, alongside the other knobs:
`pgpm.transmute('public.events', 'created_at', interval '1 month', p_drain_adaptive => true)`. Either
way the default is off (the predictable fixed `drain_batch` rate).

Now each maintenance tick measures how fast the drain is generating WAL and compares it to the rate the
database can absorb between checkpoints (`max_wal_size` / `checkpoint_timeout`). If the drain is
outrunning that, a forced checkpoint and its I/O storm are on the way, so pgpm eases the budget down
*before* the storm hits, then recovers gently once there is slack again, the same
additive-increase / halve-on-congestion idea TCP uses to ride just under a link's capacity. Your
`drain_batch` is the ceiling (a bigger batch would mean a bigger write spike, so the controller never
goes above your tuned rate); it only ever feathers *down* from there, as far as one-sixteenth of
`drain_batch` under sustained pressure. So set `drain_batch` to the rate you want when there is plenty
of slack and let pgpm back off automatically under load, instead of hand-tuning a safe fixed rate. The
backoff point is tunable (`config.drain_wal_high_water`, default 1.0 of the sustainable rate; lower
drains gentler but slower); it still
respects `drain_max_blocks`. Off by default; turn it back off with
`pgpm.set_drain_adaptive('public.events', false)`.

That WAL signal keeps the drain from storming the checkpointer, but on its own it does not make the
drain yield to *ambient query load* (a workload being starved generates little WAL, so the WAL signal
stays quiet). For that, turn on the ambient signal with `pgpm.set_drain_ambient('public.events', 2.0)`.
It counts your own client backends stuck on IO/lock waits and is self-calibrating: a fixed waiter count
would be the wrong shape, since "normal" depends on the box and workload, so instead it learns the
recent normal (an EWMA baseline) and backs off only on a *relative surge* above it -- when live waiters
exceed the factor (here 2x) times that baseline. It gets the drain out of the way of a workload surge
and resumes once the surge clears. The signal is off by default (factor 0); the WAL and ambient signals
are OR'd, so the drain feathers down when either fires.

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

## Retain

Set a policy at transmute time (`p_retain`) or later via `config.retain`, and maintenance drops
partitions past it. Retain is an interval for `time`/`uuidv7` and a count of intervals for `id`.
`null` keeps everything.

```sql
update pgpm.config set retain = '90 days' where parent_table = 'public.events'::regclass;
```

Retain uses plain `DROP` (a brief lock). `DETACH ... CONCURRENTLY` cannot run inside a function,
so for very large cold partitions you may prefer to detach them concurrently by hand.

## Incoming foreign keys

If other tables reference the table you are transmuting (e.g. `reactions(message_id) -> messages(id)`),
those FKs are handled, not ignored. Because `transmute` never rewrites the primary key, the referenced
unique key always survives partitioning, so an incoming FK to the primary key is always preservable:
no composite key, no denormalization, ever.

There is one mechanical wrinkle. The drain moves the closed tail through a standalone,
not-yet-attached child table, so a referenced row is briefly outside the parent while it is moved,
which a `NO ACTION` FK rejects. The FK therefore cannot ride through the conversion in place: it is
dropped for the duration and re-added against the new parent once the drain is done.

`transmute` offers two modes for incoming FKs:

- **`p_incoming_fks => 'error'` (default):** detect incoming FKs and refuse, mutating nothing.
- **`p_incoming_fks => 'preserve'`:** record and drop each incoming FK for the conversion (the
  referencing table is otherwise untouched), then re-add it against the new parent once the drain is
  idle.

With `'preserve'`, once the closed tail has fully drained, `pgpm.restore_incoming_fks(parent)` re-adds
each FK against the new parent (`NOT VALID` + `VALIDATE`). `maintain` calls `restore_incoming_fks`
automatically, so on the scheduled path you do nothing; on the synchronous path, call it yourself
after `drain_all`:

```sql
select pgpm.transmute('public.events', 'id', 10000000, p_incoming_fks => 'preserve');
select pgpm.drain_all('public.events', p_include_open => true);
select pgpm.restore_incoming_fks('public.events');   -- maintenance does this for you on the cron path
```

`restore_incoming_fks` is a no-op until the drain is quiescent (no closed rows in the DEFAULT, no
in-flight child partition), so it is safe to call early or repeatedly. An incoming FK that references
a non-PK key that cannot survive partitioning is refused by `'preserve'` with guidance.

After it is restored, `maintain` keeps a managed FK on a leash: a preserve-managed FK is live only
while the closed tail is empty. If a later drain appears (for example obtain falls behind and rows
land in the DEFAULT for an interval that then closes), `maintain` suspends the FK before draining
(`pgpm.suspend_incoming_fks` keeps them safe across that drain) and restores it afterward, so the
catch-up drain neither stalls nor (for a `CASCADE` / `SET NULL` FK) silently deletes or nulls the
referencing rows. Referential actions, `DEFERRABLE`-ness, and self-referential FKs are all preserved
across this cycle.

## Secondary indexes

`transmute` copies the old table's non-unique secondary indexes onto the parent as partitioned indexes
(attaching the default's existing index, no rebuild), so they propagate to every partition. Unique
secondary indexes are skipped, because a partitioned unique index must include the partition key;
recreate those on the parent by hand.

## How the conversion stays online

Two facts about Postgres drive the design:

1. You cannot convert a table to partitioned in place, so transmute renames the live table, creates a
   partitioned parent under the original name, and attaches the old table as the `DEFAULT`. No rows
   move; the app sees no change.
2. Adding a partition while the DEFAULT holds data forces a full scan of the DEFAULT under
   `ACCESS EXCLUSIVE`, which would block the workload.

pgpm sidesteps #2 for every range that receives no concurrent writes (closed past intervals on the
drain, future intervals on obtain) with a scan-skip attach:

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

## WAL and checkpoint sizing

The drain rewrites rows (a cross-partition `DELETE` + `INSERT`), so a conversion is a burst of WAL
concentrated over the drain window. If `max_wal_size` is small relative to that WAL rate (plus your
ambient write load), Postgres fires *requested* (forced) checkpoints whenever WAL hits the limit,
rather than the gentle *timed* checkpoints paced by `checkpoint_timeout`. A forced checkpoint flushes
a burst of dirty buffers; on a throughput-limited disk that flush can stall the workload for seconds.
At scale this, not the drain's row movement, is usually the worst latency you will see.

How to tell, during or after a conversion:

```sql
-- PG 17+; on 15/16 use pg_stat_bgwriter.checkpoints_req / checkpoints_timed
select num_requested, num_timed from pg_stat_checkpointer;
```

A meaningful and growing `num_requested` means `max_wal_size` is too small for your write rate.

What to do:

- **Raise `max_wal_size`** so checkpoints are time-driven, not size-driven. Rough target:
  `max_wal_size >= peak_WAL_rate x checkpoint_timeout`, with headroom. This makes checkpoints regular
  and spread (by `checkpoint_completion_target`, default 0.9) instead of bursty, and cuts WAL
  write-amplification (fewer checkpoints means fewer full-page images). The cost is longer crash
  recovery and more `pg_wal` disk.
- **`checkpoint_timeout` is a secondary, situational knob.** Raising it cuts checkpoint frequency
  further but trades more recovery time, and only helps when paired with a large enough `max_wal_size`.
- **Scaling compute is the natural moment to revisit `max_wal_size`.** A bigger instance usually means
  a higher write rate (fills `max_wal_size` faster) and, on managed platforms, a higher disk-throughput
  ceiling that absorbs checkpoint flushes better. On Supabase, `max_wal_size` and `checkpoint_timeout`
  are not scaled by compute tier (both stay at the 4GB / 5min defaults); set them yourself via the CLI,
  which reloads without a restart:

  ```bash
  supabase --experimental --project-ref <ref> postgres-config update --config max_wal_size=16GB
  ```

- **Or let pgpm throttle the producer instead.** `pgpm.set_drain_adaptive(parent, true)` paces the
  drain's own WAL down when it outruns what the checkpointer can sustain (see
  [Adaptive feathering](#adaptive-feathering-let-the-drain-tune-itself)). It is the complementary lever
  when you cannot raise `max_wal_size` enough or the disk simply cannot keep up; raising `max_wal_size`
  is the better fix when you can, and the two compose (raise the budget, keep adaptive as a safety net).

## Operations and troubleshooting

- **Pause / resume.** `select pgpm.pause('public.events');` / `select pgpm.resume('public.events');`.
  A paused table is registered but untouched by `maintain` (you can still drive `drain_*`
  manually).
- **The closed tail is growing.** `check_default()` shows `closed_rows > 0`: the table is unpaused
  but the drain is not keeping up. Raise `drain_batch`, run the cron more often, or run
  `drain_all()` once to catch up.
- **Re-transmuting a table fails with an "orphan" error.** A drain creates each child partition as a
  standalone table and attaches it only when that interval finishes draining. If a drain is
  interrupted and you then `DROP TABLE <parent> CASCADE` and recreate the table, the un-attached
  child survives the cascade (it has no dependency on the parent) and a re-transmute would collide on its
  stale keys. `transmute` detects this and refuses up front; drop the named orphan table and retry.
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
- **Empty DEFAULT kept as a safety net** (`keep_default`). In steady state obtain stays ahead so the
  DEFAULT stays empty; `check_default()` flags any stray row.
- **Retain uses plain `DROP`** (a brief lock); detach huge cold partitions concurrently by hand.
- **Unique secondary indexes** are not auto-propagated (a partitioned unique index must include the
  partition key); recreate them on the parent by hand.
- **The primary key is never rewritten.** The control column must already be part of the table's
  primary key (a table with no PK is fine); a PK that excludes the control column is refused. See
  [transmute a table](#transmute-a-table).
- **Incoming foreign keys**: refused by default, or preserved (dropped for the conversion and re-added
  against the new parent) with `p_incoming_fks => 'preserve'`; see above.
- Tested on PostgreSQL **15, 16, 17, and 18**. Boundaries align to the database timezone (UTC by
  default).
