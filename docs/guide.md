# pg_partition_magician: user guide

A task-oriented guide to converting a live PostgreSQL table to native `RANGE` partitioning and running
it. For the full function and catalog reference see [reference.md](reference.md); for the design
rationale see [REDESIGN.md](../REDESIGN.md); for a visual overview see the
[explainer](https://dventimisupabase.github.io/pg_partition_magician/).

## Contents

- [Concepts](#concepts)
- [Install](#install)
- [Transmute a table](#transmute-a-table)
- [Run it](#run-it)
- [Refine the history](#refine-the-history)
- [Monitor](#monitor)
- [Retain](#retain)
- [Incoming foreign keys](#incoming-foreign-keys)
- [Secondary indexes](#secondary-indexes)
- [How the conversion stays online](#how-the-conversion-stays-online)
- [Read consistency during a move](#read-consistency-during-a-move)
- [WAL and checkpoint sizing](#wal-and-checkpoint-sizing)
- [Operations and troubleshooting](#operations-and-troubleshooting)
- [Caveats and v1 scope](#caveats-and-v1-scope)

## Concepts

**What it manages.** pg_partition_magician transmutes an existing, unpartitioned table into a native
`RANGE`-partitioned table and then keeps it healthy: it creates future partitions ahead of your writes,
optionally splits the historical bulk into proper partitions on a schedule, and drops partitions past
your retention policy. Everything is pure SQL in the `pgpm` schema; the only runtime dependency is
`pg_cron`, and only to run the background job.

**Control kinds.** A table is partitioned on one monotonic key, of one of three kinds:

- `time`: a `timestamptz` / `timestamp` / `date` column, on an interval grid (calendar-aligned for whole
  months/years, fixed-duration otherwise). Transmute with `pgpm.transmute(..., interval '...')`.
- `id`: an `int` / `bigint` / `numeric` column, on an integer step. Covers Snowflake-style ids. Transmute
  with `pgpm.transmute(..., <bigint step>)`.
- `uuidv7`: a `uuid` column holding time-ordered UUIDv7 (or ULID-as-uuid) values, on a time grid with
  uuid-encoded bounds. A `uuid` control column is *treated as* this kind. PostgreSQL has no UUIDv7 type
  and v7-ness is not detectable from the catalog, so pgpm *assumes* a `uuid` control column is
  time-ordered and samples it ([`check_uuidv7`](reference.md#check_uuidv7)) to gate the conversion: a
  column that samples as overwhelmingly random (UUIDv4) is refused. Pass `p_force_uuidv7 => true` to
  override if you are certain it is time-ordered.

`float` / `double` are rejected: they cannot guarantee gapless boundaries and `NaN`/`Inf` poison the
ordering. Other sortable encodings (KSUID, base32 ULID, ObjectId) are not built in; partition on a
companion column instead.

**The frontier.** The frontier is the newest point the data has reached: `now()` for `time`, and
`max(control)` for `id` and `uuidv7`. An interval is "open" while the frontier is inside it (still
receiving writes) and "closed" once the frontier moves past its upper bound.

**The monolith.** Conversion moves **no rows**. It renames your original table aside and attaches it,
intact, as one bounded **coarse child** -- the *monolith* -- covering `[grid_floor(min), B)`, where `B` is
the grid boundary just above the frontier. So immediately after transmute the whole history lives in one
correct, fully-queryable partition, and the table is partitioned in form. The monolith doubles as the
current partition until the frontier crosses `B`, then it freezes.

**The DEFAULT is an empty safety net.** Alongside the monolith, transmute creates a fresh, empty
`DEFAULT` partition. It is the leading-edge net: if a write ever arrives that no real partition covers
(obtain fell behind, a backdated row, a gap), it lands here instead of erroring. In steady state obtain
keeps the frontier covered, so the `DEFAULT` stays empty. Keeping it empty is what keeps obtain cheap;
`check_default()` tells you if anything is stuck there.

**The lifecycle (what maintenance does).** One scheduled procedure, `pgpm.maintain_all()`, drives these
per table:

- **obtain**: create up to N partitions ahead of the frontier, so live writes always land in a real
  partition. With the `DEFAULT` empty this is a cheap, scan-free attach.
- **drain (the magician's assistant)**: keep the `DEFAULT` empty by evacuating the occasional stray into
  its proper partition. This is no longer the bulk mover -- it is a janitor for the leading-edge net.
- **retain**: drop partitions older than your policy.
- **refine** (optional): split the coarse monolith into finer partitions, on demand or paced across ticks.

**Refine is the bulk mover.** The historical bulk sits in the monolith until you *refine* it into
properly-sized partitions, by copying (never deleting) so there are no dead tuples and no vacuum. You can
refine by hand, enable a paced auto-refine, or never refine at all -- a coarse monolith is a correct,
permanent terminal state; you only lose partition pruning and fine-grained retention over its span until
it is split. See [Refine the history](#refine-the-history).

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

Conversion is online and moves no data. It renames your table to a coarse-child name, creates a
partitioned parent under the original name, attaches the old table as the bounded **monolith** child, and
creates a fresh empty `DEFAULT`.

### Pick the kind

There is one `pgpm.transmute`, with two type-safe overloads chosen by the width parameter: an `interval`
selects the time grid, a `bigint` step selects the integer grid. Within the time grid, a `uuid` control
column is treated as `uuidv7` and a timestamp column as plain `time`. A bare interval string literal is
ambiguous between the overloads, so interval calls must cast (`interval '...'`); an integer width needs no
cast.

```sql
-- time (timestamp/timestamptz/date control column)
select pgpm.transmute('public.events', 'created_at', interval '1 month');

-- id (bigint/numeric), 10M ids per partition
select pgpm.transmute('public.events', 'id', 10000000);

-- uuidv7 / ULID-as-uuid (a uuid control column is treated as this kind)
select pgpm.transmute('public.events', 'event_uuid', interval '1 day');
```

Transmutation registers the table **paused** by default: it is converted, but scheduled maintenance does
nothing until you `resume` it (see [Run it](#run-it)). All parameters are in the
[reference](reference.md#conversion).

### The cutover is online, with no row movement

The conversion never rewrites the primary key and never moves a row. It does do one **online, read-only
scan** of the original (to certify the monolith's bound so the attach is metadata-only), under a gentle
`SHARE UPDATE EXCLUSIVE` lock that does not block reads or writes; then a brief metadata-only
`ACCESS EXCLUSIVE` step renames, creates the parent, attaches the monolith, and creates the `DEFAULT`. So
the only `O(rows)` work is a single non-blocking read -- no index rebuild, no row rewrite, no downtime.
(Contrast the old model, which paid no scan up front but then rewrote every historical row through a
perpetual drain.)

The one hard requirement is that the **control column be `NOT NULL`** (a partition key cannot be null, and
`transmute` never scans to enforce it). A key is *not* required: if the table has a **primary key** or a
**unique constraint** that includes the control column, `transmute` reuses it in place (the parent adopts
the monolith's existing index, no rebuild); if it has neither, the table is partitioned **keyless** and no
key is synthesized (faithful to a keyless source, e.g. a plain hypertable). Postgres only requires a
partitioned key to *include* the partition key, not lead it, so a single-column key qualifies, and so does
a composite one that contains it (e.g. `(tenant_id, id)` partitioned by `id`, or `UNIQUE (device_id, ts)`
partitioned by `ts`). A few shapes are still refused with a clear error rather than partitioned on a weak
key:

- **A nullable control column**: run `ALTER TABLE ... ALTER COLUMN <control> SET NOT NULL` first.
- **A key that *excludes* the control column** (the classic `events(id PRIMARY KEY, created_at)` wanting
  time partitioning): make the control column part of the key first, or widen it with `CREATE UNIQUE INDEX
  CONCURRENTLY` then `ALTER TABLE ... ADD PRIMARY KEY USING INDEX`.
- **Only a *bare* unique index** (not a constraint) covers the control column: `ADD UNIQUE` would rebuild
  it, so promote it metadata-only first with `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE USING INDEX`.

Then re-transmute. One consequence of going keyless: `refine` is unavailable on a keyless monolith (it has
no key to identify rows for a resumable copy), so the history stays as one coarse, queryable monolith. Add
a key before transmuting if you want to refine the history into fine partitions later.

`transmute` is reversible until you commit to it: while the monolith is intact and holds the whole table,
[`untransmute`](reference.md#untransmute) cleanly restores the original. It becomes a one-way door once a
row lands outside the monolith (the frontier crosses `B`) or you refine it.

## Run it

Schedule maintenance with `pgpm.schedule()`, a thin wrapper around `pg_cron` for the one job pgpm needs.
It stays idle while the table is paused, so inspect with [`status()`](#monitor) first, then `resume`:

```sql
select pgpm.schedule();                   -- one pg_cron job (every minute) drives maintain_all() for all tables
select * from pgpm.status();              -- looks right?
select pgpm.resume('public.events');      -- go live
```

`pgpm.schedule(p_every)` takes a `pg_cron` schedule (`'* * * * *'` every minute is the default;
`'*/5 * * * *'` every 5 minutes; `'30 seconds'` for pg_cron's sub-minute syntax). pg_cron does not accept
`'1 minute'`-style interval strings; minute cadence goes through cron syntax. It registers one job named
`pgpm` that calls `maintain_all()` for every managed table in the current database, and re-running it
updates the cadence in place. `pgpm.unschedule()` removes it. Run these from the database where `pg_cron`
is installed. The raw equivalent is `cron.schedule('pgpm', '* * * * *', 'call pgpm.maintain_all()')`.

From there, each tick obtains ahead, evacuates any stray from the `DEFAULT`, applies retention, and (if
auto-refine is on) advances one refine microbatch. You can also transmute with `p_paused => false` to go
live immediately and skip `resume`.

To convert and split a table synchronously (tests, one-shot migrations) instead of waiting for the paced
cron, drive it by hand: `obtain` the forward partitions, then `refine` the monolith once it has frozen
(see [Refine the history](#refine-the-history)).

### Adaptive feathering (let the work tune itself)

Instead of fixing the rate by hand, turn on adaptive mode and let pgpm ride the per-tick budget just under
the system's spare capacity:

```sql
select pgpm.set_drain_adaptive('public.events', true);
```

Or choose it up front: `pgpm.transmute(..., p_drain_adaptive => true)`. Each maintenance tick then
measures how fast it is generating WAL and compares it to the rate the database can absorb between
checkpoints (`max_wal_size` / `checkpoint_timeout`); if it is outrunning that, a forced checkpoint and its
I/O storm are on the way, so pgpm eases the budget down *before* the storm and recovers gently once there
is slack again -- the additive-increase / halve-on-congestion idea TCP uses. Your `drain_batch` is the
ceiling; it only feathers *down* from there, as far as one-sixteenth of `drain_batch` under sustained
pressure. The same budget paces both the assistant drain and refine's microbatches.

A second, complementary signal yields to *ambient query load* (which the WAL signal misses, since a
starved workload makes little WAL). Turn it on with `pgpm.set_drain_ambient('public.events', 2.0)`: it
counts your own backends stuck on IO/lock waits, learns the recent normal (an EWMA baseline), and backs
off only on a *relative surge* above it. Off by default; the WAL and ambient signals are OR'd.

## Refine the history

After transmute, the history is one coarse monolith. **Refining** splits it into proper, fine-grained
partitions. It is optional: a coarse monolith is correct and queryable forever; refining is what restores
partition pruning and fine-grained retention over the historical span.

How refine works, and why it is cheap: it **copies** the monolith's rows into new fine children and swaps
them in atomically, then drops the now-empty source. Because it copies rather than deletes, the kept
partitions have no dead tuples and need no vacuum; the cost is transient extra disk (roughly 2x the
range being refined, while the copies coexist with the source) and the one-time copy I/O. A sub-range
entirely below the retention horizon is reclaimed rather than materialized, so refining never builds a
partition that retention would immediately drop.

A child can only be refined once it is **frozen** -- its whole range below the current frontier, so no
live write still lands in it. The monolith freezes once the frontier crosses `B`.

**Refine by hand** (synchronous, atomic, one transaction):

```sql
select pgpm.refine_history('public.events');   -- split the oldest coarse child to the configured step
```

`refine_history` refines the oldest coarse child (the monolith) to the configured partition step. For a
hierarchical split (monolith to per-year to per-month, to bound the transient disk on a tight volume),
call `pgpm.refine(parent, child, target_step)` with chosen steps.

**Auto-refine** (paced across maintenance ticks):

```sql
select pgpm.set_refine('public.events', '1 month');   -- feather the monolith toward monthly, one microbatch per tick
```

With auto-refine on, each `maintain` tick advances one budget-sized microbatch of the oldest frozen coarse
child toward the target step, under the same adaptive budget as the drain. It is off by default
(`set_refine(parent, null)` turns it back off) and always safe to enable: it only paces refinement; it
never starts on a child that is not frozen or whose range still has strays in the `DEFAULT`.

Refine **copies**; it never deletes from the source. The coarse child stays whole and attached until one
atomic swap detaches it, attaches the fine children, and drops it. So unlike the drain, a refine -- the
paced, cross-tick auto-refine included -- never undercounts: every row stays visible in the monolith the
whole time, and the swap is atomic, so a concurrent reader never sees a partial state. The kept fine
children only ever receive inserts, so there are no dead tuples and no vacuum. (The one moment refine
touches a foreign key is that swap; see [incoming foreign keys](#incoming-foreign-keys).)

**Disk.** Refining needs transient headroom (about 2x the span being refined) for the copies before the
source is dropped. On an elastic or auto-scaling volume this is absorbed; on a fixed volume, refine
hierarchically (coarse first, then each coarse child) so each step's footprint stays bounded, or skip
refinement and keep the coarse monolith.

## Monitor

```sql
select * from pgpm.status();        -- one row per managed table: partitions, backlog, progress
```

`status()` surfaces, beyond the static config:

- **`coarse_partitions` and `history_unrefined`** -- how many attached partitions are still coarse
  (wider than one step), and whether any remain. `history_unrefined = true` is the refinement backlog:
  pruning and fine retention are suspended over that coarse span until it is refined.
- **`closed_rows` / `default_rows`** -- the assistant drain's backlog: rows in the `DEFAULT` that should
  have a real partition. In steady state this is **zero** (the monolith holds the history; the `DEFAULT`
  is the empty net). A non-zero `closed_rows` means a stray landed there and has not yet been evacuated.
- **`last_drained` / `drain_skips`** -- progress versus stall: a non-zero `closed_rows` with a stale
  `last_drained` and a climbing `drain_skips` is a wedged drain; falling `closed_rows` with
  `drain_skips ~ 0` is merely slow.
- **`inflight_partitions`** -- children created but not yet attached: a drain mid-move, or a refine's
  in-progress copies. A *drain* child holds rows not yet visible through the parent (use
  [`snapshot()`](#read-consistency-during-a-move) for a complete read); a *refine* copy-child holds
  duplicates of rows still in the monolith, so the parent count is already complete -- it is a
  transient-disk signal, not a read gap.
- **`fks_suspended` / `fks_unvalidated`** -- preserve-managed incoming FKs currently dropped (RI off)
  versus re-added `NOT VALID` but blocked from validation by pre-existing orphans.

For `uuidv7` tables, confirm the column really is time-ordered (not random UUIDv4):

```sql
select * from pgpm.check_uuidv7('public.events', 'event_uuid');
```

A low `fraction` means the values do not decode to plausible timestamps and the table should not be
partitioned on that column. For an `id`-partitioned table where you want calendar retention, check that a
timestamp column rises with the id:

```sql
select * from pgpm.check_time_monotonic('public.events', 'id', 'created_at');
```

## Retain

Set a policy at transmute time (`p_retain`) or later via `config.retain`, and maintenance drops partitions
past it. Retain is an interval for `time`/`uuidv7` and a count of intervals for `id`. `null` keeps
everything.

```sql
update pgpm.config set retain = '90 days' where parent_table = 'public.events'::regclass;
```

Retain drops a partition only when its **whole range** is older than the horizon, using plain `DROP` (a
brief lock). Two consequences in the monolith model:

- **Retention is suspended over un-refined coarse history.** A coarse monolith spanning the horizon is
  not dropped (it still holds within-horizon data), so its aged span is not reclaimed until you refine
  it. Refine is retention-aware: it skips the below-horizon sub-ranges (it never copies them; they are
  discarded with the source at the swap) instead of materializing partitions only to drop them. So on a
  table you want aggressively retained, enable
  auto-refine (or refine by hand) to let retention reach the history.
- **The assistant drain reclaims aged strays in place.** If a stray ages past the horizon while still in
  the `DEFAULT`, the drain `DELETE`s it straight out (logged `retain_reclaim`) rather than materializing a
  doomed partition.

**Retention is a standing floor, not just an aging process.** The policy is "no data with a control value
below the horizon persists" -- aging is just the usual way rows cross that line. A row inserted with a
control value *already* past the horizon (a backdated or late-arriving record) is subject to retention
immediately: the next maintenance cycle reclaims it, exactly as any retention system would. The `INSERT`
succeeds; a later, separate maintenance transaction removes the row per policy. If you need late-arriving
data kept for a window *from arrival*, retain on an ingestion timestamp rather than event time, or widen
the policy.

## Incoming foreign keys

If other tables reference the table you are transmuting (e.g. `reactions(message_id) -> messages(id)`),
those FKs are handled, not ignored. Because `transmute` never rewrites the primary key, the referenced
unique key always survives partitioning, so an incoming FK to the primary key is always preservable: no
composite key, no denormalization, ever.

There is one mechanical wrinkle. The assistant drain moves referenced rows through a standalone,
not-yet-attached child, so a referenced row is briefly outside the parent, which a `NO ACTION` FK would
reject and a `CASCADE`/`SET NULL` FK would silently honour. So the FK cannot ride through in place during a
drain: it is dropped for the conversion and re-added against the new parent. (Refine is different -- it
copies, never moving a referenced row out of the parent -- so the multi-tick copy needs no such leash; only
its atomic swap touches the FK, see below.)

`transmute` offers two modes for incoming FKs:

- **`p_incoming_fks => 'error'` (default):** detect incoming FKs and refuse, mutating nothing.
- **`p_incoming_fks => 'preserve'`:** record and drop each incoming FK for the conversion (the referencing
  table is otherwise untouched), then re-add it against the new parent once maintenance is idle.

With `'preserve'`, `pgpm.restore_incoming_fks(parent)` re-adds each FK once the closed tail has drained;
`maintain` calls it automatically, so on the scheduled path you do nothing. It is a no-op until the drain
is quiescent (no closed rows in the `DEFAULT`, no in-flight *drain* child -- a refine's copy-children do not
count, since they never take a referenced row out of the parent), so it is safe to call early or
repeatedly. Because the monolith holds every referenced row attached from the moment of cutover, with no
closed tail to wait for, the FK is typically restorable immediately after transmute.

```sql
select pgpm.transmute('public.events', 'id', 10000000, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('public.events');   -- maintenance does this for you on the cron path
```

Two honest points about the window the FK is dropped:

- **RI is off on the referencing table while the FK is down.** Writes to the referencing table go
  unchecked during that window, and `status().fks_suspended` surfaces it. `'preserve'` is opt-in; if the
  referencing table takes heavy writes, keep the window short (restore promptly) or `pause`.
- **An orphan written during that window will not brick the restore.** The re-add is split: `ADD
  CONSTRAINT ... NOT VALID` (which already enforces every *new* write) is committed separately from
  `VALIDATE`. If a pre-existing orphan blocks `VALIDATE`, the FK is left `NOT VALID` (still enforcing new
  writes, surfaced by `status().fks_unvalidated`) rather than rolled back. List blockers with
  `pgpm.incoming_fk_orphans(parent)`, remove them, then `pgpm.validate_incoming_fks(parent)`:

```sql
select * from pgpm.incoming_fk_orphans('public.events');   -- which FK, how many orphan rows
-- ... delete or fix the offending referencing rows ...
select pgpm.validate_incoming_fks('public.events');        -- validates the now-clean FKs
```

For the full step-by-step recovery, see the runbook entry
[Referential-integrity violations after a `preserve` drain](runbook.md#referential-integrity-violations-after-a-preserve-drain).

After it is restored, `maintain` keeps a managed FK on a leash: it is live only while the closed tail is
empty. If a later drain appears (obtain falls behind and rows land in the `DEFAULT` for an interval that
then closes), `maintain` suspends the FK before draining (`pgpm.suspend_incoming_fks`) and restores it
afterward. Referential actions, `DEFERRABLE`-ness, and self-referential FKs are all preserved across the
cycle.

Auto-refine needs **no such leash during the copy**: a refine copies, so every referenced row stays in the
monolith and is never outside the parent. The single exception is the swap's `DETACH` -- Postgres refuses
to detach a partition whose rows are still referenced -- so the swap transiently drops the incoming FK(s)
and re-adds them *within that one atomic transaction*. No other session ever observes RI off; there is no
multi-tick suspension window the way the drain has, and the synchronous `refine()` is atomic end to end.

## Secondary indexes

`transmute` copies the old table's non-unique secondary indexes onto the parent as partitioned indexes
(reusing the monolith's existing index, no rebuild), so they propagate to every partition, including the
fine children that refine creates. A unique secondary index is carried the same way **when its key
includes the partition key** (so global uniqueness is genuinely preserved). One whose key excludes the
partition key cannot be a partitioned unique index, so `transmute` **refuses** rather than silently
dropping the guarantee: add the partition key to that index, or drop it, then re-transmute.

## How the conversion stays online

Two facts about Postgres drive the design:

1. You cannot convert a table to partitioned in place, so transmute renames the live table, creates a
   partitioned parent under the original name, and attaches the old table as a bounded child. No rows
   move; the app sees no change.
2. Attaching a partition whose rows are not certified in range forces a scan under `ACCESS EXCLUSIVE`,
   which would block the workload.

pgpm sidesteps #2 with a scan-skip attach: certify the bound with a validated `CHECK` under the gentle,
non-blocking `SHARE UPDATE EXCLUSIVE` lock *before* the attach, so the attach itself is metadata-only.

```sql
ADD CONSTRAINT b CHECK (control >= lo AND control < hi) NOT VALID  -- catalog only, instant
VALIDATE CONSTRAINT b                                              -- the scan, under SHARE UPDATE EXCLUSIVE (non-blocking)
ATTACH PARTITION ...                                               -- scan skipped, metadata-only
```

The monolith attaches this way at transmute (one online scan of the original). `obtain`'s forward
partitions need no scan at all, because the `DEFAULT` they would be checked against is empty (this is why
keeping the `DEFAULT` empty matters). Refine's fine children are born with their bound `CHECK`, so they
too attach metadata-only. The one rule that keeps it safe: never certify a range that is still receiving
writes -- the monolith covers up to `B` (a boundary above the frontier) precisely so the current interval
lives inside it, and refine only touches frozen children.

## Read consistency during a move

This is the one correctness caveat worth understanding. We would rather state it plainly than bury it,
and in this model it is much narrower than it used to be.

**The gap belongs to the assistant drain alone.** When the paced drain evacuates a stray it `DELETE`s the
row out of the `DEFAULT` and re-`INSERT`s it into a standalone, not-yet-attached child across separate
transactions. A query against the parent only scans attached partitions, so a plain `SELECT ... FROM parent`
issued mid-move **undercounts** the range being moved. The rows are never lost; they are temporarily not
reachable through the parent.

**Refine never opens this gap.** Refine *copies*; it never deletes from the source. The coarse child stays
whole and attached until one atomic swap, so every row is visible through the parent the entire time --
paced auto-refine included. (Its in-flight copies are duplicates of rows still in the monolith, which is why
`snapshot()` must *not* union them, and does not.) The synchronous paths are also gap-free: `refine()` /
`refine_history()` and `drain_all()` each run in one transaction. So the gap is specific to the *paced
drain*, only for the single range in flight, only while it moves. Reads of recent data are never affected:
the drain only ever moves old, closed ranges.

**Reads: the `snapshot()` escape hatch.** If a consistency-sensitive reader (a `COUNT(*)`, a logical
backup, a reconciliation) needs the complete set during a move, query it inline:

```sql
select count(*) from pgpm.snapshot(null::public.events);  -- the parent UNION every in-flight child
```

`snapshot()` is a read-only set-returning function that `UNION`s the parent with every in-flight *drain*
child (it deliberately skips a refine's copy-children, whose rows are already in the attached monolith, so
it never double-counts). You pass the table as a typed-`NULL` anchor (`null::public.events`) because a
function's row shape is fixed at plan time and cannot be inferred from a `regclass` value. It is always
fresh and leaves nothing behind. One honest cost: it is an **optimization fence** (the in-flight child set
is dynamic, so a `WHERE` on top does not push down); fine for a `COUNT` or full read, but for a
heavily-filtered read on a large table a hand-written `parent UNION ALL <child>` plans better.

**Writes: there is no fix for the paced drain.** A write through the parent that targets a row the drain has
*already moved* into an unattached child finds no row and is a silent no-op until the interval attaches; an
`INSERT ... ON CONFLICT` (upsert) on such a key can write a duplicate that later wedges the drain on a
duplicate-key error. A fresh `INSERT` is never affected (it routes to the `DEFAULT` and the next batch
sweeps it). Refine does not have this problem -- it never removes a row from the parent -- so mutating old
rows during a refine is safe. If you mutate rows a drain may be moving (a ledger with backdated
adjustments, a document store editing years-old rows), prefer the synchronous `drain_all()` (one
transaction, no gap) and `pause` the table while you do, or partition on a different axis.

## WAL and checkpoint sizing

Moving rows rewrites them (a cross-partition `DELETE` + `INSERT`), so a **refine** is a burst of WAL
concentrated over the refine window (the steady-state assistant drain is tiny by comparison). If
`max_wal_size` is small relative to that WAL rate plus your ambient write load, Postgres fires *requested*
(forced) checkpoints whenever WAL hits the limit, rather than gentle *timed* checkpoints. A forced
checkpoint flushes a burst of dirty buffers; on a throughput-limited disk that flush can stall the
workload for seconds. At scale this, not the row movement itself, is usually the worst latency you see.

How to tell:

```sql
-- PG 17+; on 15/16 use pg_stat_bgwriter.checkpoints_req / checkpoints_timed
select num_requested, num_timed from pg_stat_checkpointer;
```

A meaningful and growing `num_requested` means `max_wal_size` is too small for your write rate. What to do:

- **Raise `max_wal_size`** so checkpoints are time-driven. Rough target:
  `max_wal_size >= peak_WAL_rate x checkpoint_timeout`, with headroom. The cost is longer crash recovery
  and more `pg_wal` disk. On Supabase, `max_wal_size`/`checkpoint_timeout` are not scaled by tier; set
  them via the CLI (reloads without restart):

  ```bash
  supabase --experimental --project-ref <ref> postgres-config update --config max_wal_size=16GB
  ```

- **Or let pgpm throttle the producer.** Adaptive feathering paces the work's own WAL down when it
  outruns what the checkpointer can sustain, and auto-refine spreads the refine across ticks so the WAL
  burst becomes a trickle. The two compose: raise `max_wal_size` when you can, keep adaptive as a safety
  net.

## Operations and troubleshooting

For step-by-step procedures when an alert fires, see the [runbook](runbook.md). Quick reference:

- **Pause / resume.** `select pgpm.pause('public.events');` / `select pgpm.resume('public.events');`. A
  paused table is registered but untouched by `maintain` (you can still drive `drain_*`/`refine` by hand).
- **A stray is stuck in the `DEFAULT`.** `check_default()` shows `closed_rows > 0`: the table is unpaused
  but the assistant drain has not evacuated it. Raise `drain_batch`, run the cron more often, or
  `drain_all()` once.
- **History is not being split.** `status().history_unrefined` is true and you want fine partitions:
  enable auto-refine (`set_refine`) or run `refine_history` by hand once the monolith has frozen.
- **Re-transmuting a table fails with an "orphan" error.** A drain or interrupted refine creates child
  partitions as standalone tables before attaching them; an un-attached child survives a `DROP TABLE
  <parent> CASCADE`. `transmute` detects a leftover and refuses up front; drop the named orphan and retry.

## Caveats and v1 scope

- **Dimensions:** `time` (interval step; whole-month or fixed-duration; mixing rejected), `id`
  (bigint/numeric step), `uuidv7`/ULID-as-uuid (time grid, uuid bounds). `float`/`double` rejected; other
  encodings partition on a companion column.
- **Monotonicity is the precondition.** UUIDv7/ULID are ms-resolution monotonic with a small
  clock-skew/late-arrival window; the don't-close-until-frontier-past rule plus the `DEFAULT` net absorb
  stragglers. Arbitrary backdated keys break it.
- **The cutover is online but not instant:** one non-blocking, read-only scan of the original, then a
  brief metadata cutover. No row movement, no PK rewrite, no index rebuild.
- **The history starts coarse.** It is one monolith partition until refined; until then, pruning and
  fine-grained retention are suspended over its span. A coarse monolith is a valid permanent state.
- **Refine needs transient disk** (about 2x the span being refined) and copies the rows; both the
  synchronous and the paced auto-refine path are gap-free (the source stays whole and attached until the
  atomic swap, which transiently drops and re-adds any incoming FK within one transaction). The
  read-consistency gap below is the *drain's*, not refine's.
- **The empty `DEFAULT` is the safety net** (`keep_default`); `check_default()` flags any stray.
- **Retain uses plain `DROP`** (a brief lock); retention over coarse history waits on refine.
- **Unique secondary indexes** are carried when their key includes the partition key; otherwise refused.
- **The key is never rewritten;** a primary key or unique constraint that includes the control column is
  reused in place, and a keyless table is partitioned keyless. The control column must be `NOT NULL`.
- **Incoming foreign keys** are refused by default, or preserved (dropped for the conversion, re-added
  against the new parent) with `p_incoming_fks => 'preserve'`.
- **Mid-move reads undercount on the paced paths; writes to moved rows no-op.** Inherent to an online
  move; see [Read consistency during a move](#read-consistency-during-a-move). The synchronous paths avoid
  it entirely.
- Tested on PostgreSQL **15, 16, 17, and 18**. Boundaries align to the database timezone (UTC by default).
