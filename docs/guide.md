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
- [Regrain the history](#regrain-the-history)
- [Monitor](#monitor)
- [Retain](#retain)
- [Incoming foreign keys](#incoming-foreign-keys)
- [Secondary indexes](#secondary-indexes)
- [How the conversion avoids a rewrite](#how-the-conversion-avoids-a-rewrite)
- [Read consistency](#read-consistency)
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

**There is no DEFAULT partition.** Alongside the monolith, transmute builds a *forward grid*: real,
bounded partitions running `config.obtain` steps ahead of the write frontier. A write that no partition
covers is **refused**, not parked:

```text
ERROR:  no partition of relation "events" found for row
```

That is deliberate. A `DEFAULT` would absorb such a write silently and need a background process to file
it away later, which is precisely the machinery, and the referential-integrity window, that pgpm removed.
The trade is that `config.obtain x partition_step` is both your slack if maintenance stalls and a ceiling
on how far ahead you may write, so size it for your grid: 30 steps is a month on a daily one.

**The lifecycle (what maintenance does).** One scheduled procedure, `pgpm.maintain_all()`, drives these
per table:

- **obtain**: create up to N partitions ahead of the frontier, so live writes always land in a real
  partition. Pure catalog work: there is no `DEFAULT` to scan, so nothing is proven and nothing is moved.
  This is also pgpm's *only* protection against a write with nowhere to go, since a row outside the grid
  is refused rather than parked. `config.obtain x partition_step` is therefore both your slack if
  maintenance stalls and a ceiling on how far ahead you may write.
- **retain**: drop partitions older than your policy.
- **regrain** (optional): split the coarse monolith into finer partitions, on demand or paced across ticks.

**Regrain is the bulk mover.** The historical bulk sits in the monolith until you *regrain* it into
properly-sized partitions, by copying (never deleting) so there are no dead tuples and no vacuum. You can
regrain by hand, enable a paced auto-regrain, or never regrain at all -- a coarse monolith is a correct,
permanent terminal state; you only lose partition pruning and fine-grained retention over its span until
it is split. See [Regrain the history](#regrain-the-history).

## Install

`pgpm_core/install.sql` is the single source of truth: pure, idempotent SQL with no psql
metacommands. It ships through three channels, all built from that one file.

The simplest path, on any Postgres you can run SQL against:

```bash
psql "$DATABASE_URL" -f pgpm_core/install.sql
```

For a SQL client that does not process psql metacommands (a dashboard editor, say), build a
self-contained `BEGIN/COMMIT`-wrapped bundle and paste it in:

```bash
scripts/build_install_bundle.sh pgpm_core/install.sql dist/pg_partition_magician-bundle.sql
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
psql "$DATABASE_URL" -f pgpm_core/uninstall.sql
```

## Transmute a table

Conversion moves no data. It renames your table to a coarse-child name, creates a partitioned parent
under the original name, attaches the old table as the bounded **monolith** child, and creates a fresh
empty `DEFAULT`. It does read the original once, and the table is locked while it does; see
[The cutover moves no rows](#the-cutover-moves-no-rows).

### Pick the kind

There is one `pgpm.transmute`, with two type-safe overloads chosen by the width parameter: an `interval`
selects the time grid, a `bigint` step selects the integer grid. Within the time grid, a `uuid` control
column is treated as `uuidv7` and a timestamp column as plain `time`. A bare interval string literal is
ambiguous between the overloads, so interval calls must cast (`interval '...'`); an integer width needs no
cast.

```sql
-- time (timestamp/timestamptz/date control column)
call pgpm.transmute('public.events', 'created_at', interval '1 month');

-- id (bigint/numeric), 10M ids per partition
call pgpm.transmute('public.events', 'id', 10000000);

-- uuidv7 / ULID-as-uuid (a uuid control column is treated as this kind)
call pgpm.transmute('public.events', 'event_uuid', interval '1 day');
```

Transmutation registers the table **paused** by default: it is converted, but scheduled maintenance does
nothing until you `resume` it (see [Run it](#run-it)). All parameters are in the
[reference](reference.md#conversion).

### The cutover moves no rows

The conversion never rewrites the primary key and never moves a row. Its only `O(rows)` work is a single
read-only scan of the original, which certifies the monolith's bound so the later attach is metadata-only.
Everything after that is a metadata flip: rename, create the parent, attach the monolith, create the
`DEFAULT`. No index rebuild, no row rewrite.

**The table is locked for the duration of that scan.** `transmute` runs in one transaction, and the
`ALTER TABLE` that adds the bound takes an `ACCESS EXCLUSIVE` lock which is therefore held until the
conversion commits, scan included. `ACCESS EXCLUSIVE` conflicts with everything, so reads and writes both
wait. Size a maintenance window from the row count:

| rows | table locked for |
|---|---|
| 1M | ~30 ms |
| 5M | ~170 ms |
| 10M | ~490 ms |

Measured on PostgreSQL 17 with the table cached in memory. A table larger than RAM makes the scan
I/O-bound, so treat these as a floor rather than an estimate, and measure on a restored copy of your own
data before converting a large table.
(Contrast a model that pays no scan up front but then rewrites every historical row.)

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

Then re-transmute. One consequence of going keyless: `regrain` is unavailable on a keyless monolith (it has
no key to identify rows for a resumable copy), so the history stays as one coarse, queryable monolith. Add
a key before transmuting if you want to regrain the history into fine partitions later.

`transmute` is reversible until you commit to it: while the monolith is intact and holds the whole table,
[`untransmute`](reference.md#untransmute) cleanly restores the original. It becomes a one-way door once a
row lands outside the monolith (the frontier crosses `B`) or you regrain it.

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
auto-regrain is on) advances one regrain microbatch. You can also transmute with `p_paused => false` to go
live immediately and skip `resume`.

To convert and split a table synchronously (tests, one-shot migrations) instead of waiting for the paced
cron, drive it by hand: `obtain` the forward partitions, then `regrain` the monolith once it has frozen
(see [Regrain the history](#regrain-the-history)).

Regrain's pace is set by `config.regrain_batch`, the rows copied per microbatch, with an optional
`regrain_max_blocks` cap so wide rows cannot make one batch huge. It is a fixed rate: pgpm used to run a
closed-loop controller that rode the budget against WAL and ambient I/O pressure, but that existed to pace
the *drain*, and the drain is gone. Regrain copies old, frozen data at whatever rate you choose, and the
work is bounded by the coarse child rather than by the write rate.

## Regrain the history

After transmute, the history is one coarse monolith. **Regraining** splits it into proper, fine-grained
partitions. It is optional: a coarse monolith is correct and queryable forever; regraining is what restores
partition pruning and fine-grained retention over the historical span.

How regrain works, and why it is cheap: it **copies** the monolith's rows into new fine children and swaps
them in atomically, then drops the now-empty source. Because it copies rather than deletes, the kept
partitions have no dead tuples and need no vacuum; the cost is transient extra disk (roughly 2x the
range being regrained, while the copies coexist with the source) and the one-time copy I/O. A sub-range
entirely below the retention horizon is reclaimed rather than materialized, so regraining never builds a
partition that retention would immediately drop.

A child can only be regrained once it is **frozen** -- its whole range below the current frontier, so no
live write still lands in it. The monolith freezes once the frontier crosses `B`.

**Regrain by hand** (synchronous, atomic, one transaction):

```sql
select pgpm.regrain_history('public.events');   -- split the oldest coarse child to the configured step
```

`regrain_history` regrains the oldest coarse child (the monolith) to the configured partition step. For a
hierarchical split (monolith to per-year to per-month, to bound the transient disk on a tight volume),
call `pgpm.regrain(parent, child, target_step)` with chosen steps.

**Auto-regrain** (paced across maintenance ticks):

```sql
select pgpm.set_regrain('public.events', '1 month');   -- feather the monolith toward monthly, one microbatch per tick
```

With auto-regrain on, each `maintain` tick advances one budget-sized microbatch of the oldest frozen coarse
child toward the target step, under the same adaptive budget as the drain. It is off by default
(`set_regrain(parent, null)` turns it back off) and always safe to enable: it only paces regraining; it
never starts on a child that is not frozen or whose range still has strays in the `DEFAULT`.

Regrain **copies**; it never deletes from the source. The coarse child stays whole and attached until one
atomic swap detaches it, attaches the fine children, and drops it. So unlike the drain, a regrain -- the
paced, cross-tick auto-regrain included -- never undercounts: every row stays visible in the monolith the
whole time, and the swap is atomic, so a concurrent reader never sees a partial state. The kept fine
children only ever receive inserts, so there are no dead tuples and no vacuum. (The one moment regrain
touches a foreign key is that swap; see [incoming foreign keys](#incoming-foreign-keys).)

**Disk.** Regraining needs transient headroom (about 2x the span being regrained) for the copies before the
source is dropped. On an elastic or auto-scaling volume this is absorbed; on a fixed volume, regrain
hierarchically (coarse first, then each coarse child) so each step's footprint stays bounded, or skip
regraining and keep the coarse monolith.

## Monitor

```sql
select * from pgpm.status();        -- one row per managed table: partitions, backlog, progress
```

`status()` surfaces, beyond the static config:

- **`coarse_partitions` and `history_unregrained`** -- how many attached partitions are still coarse
  (wider than one step), and whether any remain. `history_unregrained = true` is the regraining backlog:
  pruning and fine retention are suspended over that coarse span until it is regrained.
- **`newest_bound`** -- the top of the forward grid, and therefore the write-ahead ceiling. An insert
  past it is refused. If this stops advancing, maintenance has stalled and you are burning through your
  slack.
- **`inflight_partitions`** -- regrain copy-children created but not yet attached. These hold duplicates
  of rows still in the monolith, so the parent's count is already complete: it is a transient-disk
  signal, not a read gap.
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

If [`pg_flight_recorder`](https://github.com/dventimisupabase/pg_flight_recorder) is installed,
`pgpm.impact_report('public.events')` correlates pgpm's operation log against the database telemetry PGFR
sampled, reporting what a conversion did to the workload (forced checkpoints, WAL, top waits, query latency)
over the window pgpm was active, and `pgpm.feathering_validation('public.events')` cross-checks whether each
adaptive backoff matched real pressure. Both ship with `pgpm_core`; PGFR is never a dependency, they just
raise a clear error until it's installed. See the
[reference](reference.md#observability-with-pg_flight_recorder-observe).

## Retain

Set a policy at transmute time (`p_retain`) or later via `config.retain`, and maintenance drops partitions
past it. Retain is an interval for `time`/`uuidv7` and a count of intervals for `id`. `null` keeps
everything.

```sql
update pgpm.config set retain = '90 days' where parent_table = 'public.events'::regclass;
```

Retain drops a partition only when its **whole range** is older than the horizon, using plain `DROP` (a
brief lock) when nothing references the table. Two consequences in the monolith model:

- **Retention is suspended over un-regrained coarse history.** A coarse monolith spanning the horizon is
  not dropped (it still holds within-horizon data), so its aged span is not reclaimed until you regrain
  it. Regrain is retention-aware: it skips the below-horizon sub-ranges (it never copies them; they are
  discarded with the source at the swap) instead of materializing partitions only to drop them. So on a
  table you want aggressively retained, enable
  auto-regrain (or regrain by hand) to let retention reach the history.
- **A referenced partition is retired in two steps, not one.** If any foreign key points at the managed
  table, a plain `DROP` cannot reclaim the partition at all, so retention detaches it first. That path is
  asynchronous and needs `pgpm.schedule()`; see [Retention with an incoming foreign
  key](#retention-with-an-incoming-foreign-key).

**Retention is a standing floor, not just an aging process.** The policy is "no data with a control value
below the horizon persists" -- aging is just the usual way rows cross that line. A row inserted with a
control value *already* past the horizon (a backdated or late-arriving record) is subject to retention
immediately: the next maintenance cycle reclaims it, exactly as any retention system would. The `INSERT`
succeeds; a later, separate maintenance transaction removes the row per policy. If you need late-arriving
data kept for a window *from arrival*, retain on an ingestion timestamp rather than event time, or widen
the policy.

**Drops can also be driven from outside the schedule.** `pgpm.retire(parent, child)` is the sanctioned
single-partition drop -- the same protocol `retain` runs (write-block ensure, archive-coverage check,
`DROP`, bookkeeping), callable one partition at a time. It never drops anything retention would not
(the partition's whole range must be past the horizon), and each partition is claim-guarded so several
cooperating callers can work alongside the scheduled `retain` without stepping on each other. See
`retire` in the [reference](reference.md#retire).

### Archiving before a drop

A partition gets a `BEFORE INSERT OR UPDATE OR DELETE` trigger the moment it crosses the retention
horizon, independent of whether or how it is archived -- a backdated write into an eligible,
not-yet-dropped range is rejected outright rather than silently diverging an archive from what is
still live. If you also want the *drop* itself to wait until archiving has actually happened, set
`config.archive_fn` to a resumable archive strategy with `pgpm.set_archive_fn`:

```sql
select pgpm.set_archive_fn('public.events', 'myschema.my_archiver(regclass,name,text,text)'::regprocedure);
```

`null` (the default) means no archiving -- a write-blocked partition is immediately drop-ready, the
same behavior as before this contract existed. With `archive_fn` set, `pgpm.maintain()` archives each
eligible child in bounded chunks on its own schedule (sized by `config.archive_byte_budget`), and
`pgpm.retire()` will not drop a child until `pgpm._archive_fully_covered` confirms every chunk has
landed -- a child mid-archive is a normal, retryable state, not a failure, and nothing here fails
loudly the way a hook used to; `retire()` just returns `false` and tries again next tick. See [the
reference](reference.md#archive-strategy-contract) for the full calling contract
(`archive_fn(p_parent, p_child, p_lo, p_hi) returns pgpm.archive_result`), and [the pgpm_archive
add-on](../pgpm_archive/README.md) for two ready-made S3 strategies
(`pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet`) built on this contract.

`status().retain_backlog` tracks partitions still waiting on their turn to drop; it falling tick over
tick is normal draining (either a paced backlog or archiving still catching up), while flat with
`retain_drop_failures` climbing means something else is wrong -- an unexpected `DROP` failure, not
archiving simply not having caught up yet (that shows as `retain_drop_failures` staying at zero). See
the runbook's
[retention entry](runbook.md#storage-is-not-dropping-despite-a-retention-policy) for the full
diagnostic.

## Incoming foreign keys

If other tables reference the table you are transmuting (e.g. `reactions(message_id) -> messages(id)`),
those FKs are handled, not ignored. Because `transmute` never rewrites the primary key, the referenced
unique key always survives partitioning, so an incoming FK to the primary key is always preservable: no
composite key, no denormalization, ever.

There is one mechanical wrinkle. The drain moves referenced rows through a standalone,
not-yet-attached child, so a referenced row is briefly outside the parent, which a `NO ACTION` FK would
reject and a `CASCADE`/`SET NULL` FK would silently honour. So the FK cannot ride through in place during a
drain: it is dropped for the conversion and re-added against the new parent. (Regrain is different -- it
copies, never moving a referenced row out of the parent -- so the multi-tick copy needs no such leash; only
its atomic swap touches the FK, see below.)

`transmute` offers two modes for incoming FKs:

- **`p_incoming_fks => 'error'` (default):** detect incoming FKs and refuse, mutating nothing.
- **`p_incoming_fks => 'preserve'`:** record and drop each incoming FK for the conversion (the referencing
  table is otherwise untouched), then re-add it against the new parent once maintenance is idle.

With `'preserve'`, `pgpm.restore_incoming_fks(parent)` re-adds each FK once the closed tail has drained;
`maintain` calls it automatically, so on the scheduled path you do nothing. It is a no-op until the drain
is quiescent (no closed rows in the `DEFAULT`, no in-flight *drain* child -- a regrain's copy-children do not
count, since they never take a referenced row out of the parent), so it is safe to call early or
repeatedly. Because the monolith holds every referenced row attached from the moment of cutover, with no
closed tail to wait for, the FK is typically restorable immediately after transmute.

```sql
call pgpm.transmute('public.events', 'id', 10000000, p_incoming_fks => 'preserve');
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

Auto-regrain needs **no such leash during the copy**: a regrain copies, so every referenced row stays in the
monolith and is never outside the parent. The single exception is the swap's `DETACH` -- Postgres refuses
to detach a partition whose rows are still referenced -- so the swap transiently drops the incoming FK(s)
and re-adds them *within that one atomic transaction*. No other session ever observes RI off; there is no
multi-tick suspension window the way the drain has, and the synchronous `regrain()` is atomic end to end.

### Retention with an incoming foreign key

A foreign key pointing at the managed table changes how [retention](#retain) reclaims a partition, whether
or not it was `preserve`-managed, and whether or not anything actually references the aged rows.

`DROP TABLE <partition>` is refused on a pure **catalog** dependency: an FK against a partitioned parent
puts one constraint row per referenced partition on the referencing table, and the refusal is identical
whether one row references, zero rows reference, or the referencing table is empty. So retention detaches
first, which severs that per-partition constraint and leaves the drop unguarded. The referencing table's
own foreign key survives and keeps enforcing.

The detach has to be `CONCURRENTLY` -- the plain form holds `ACCESS EXCLUSIVE` on your managed table for
as long as it takes to scan the *referencing* table -- and PostgreSQL will not run that from a function.
So pgpm dispatches it to a standing `pgpm_detach` cron job and completes the drop on a later tick. Three
things follow, and none of them are optional:

- **`pgpm.schedule()` is required to retire a referenced partition.** Without the `pgpm_detach` job there
  is nowhere to dispatch to, and `retire` logs `fail_retain_detach` rather than reclaiming. If you
  scheduled pgpm before upgrading, re-run `pgpm.schedule()` once to create the second job.
- **Retirement spans at least one extra tick.** `status().retain_detaching` counts partitions whose
  detach is in flight. Retention was already eventual, so this lengthens a delay rather than adding one.
- **Writes to the *referencing* table are blocked while the detach runs**, once per retirement, for a
  duration set by that table's size. Reads of it, and your managed table entirely, are unaffected. This is
  irreducible: it is PostgreSQL proving the foreign key still holds. An index on the referencing column is
  ordinary good practice but does not reduce it.

**When a live row genuinely references an aged one**, pgpm executes the policy you already declared in the
foreign key's `ON DELETE` clause, rather than inventing one:

| `ON DELETE` | what happens to the referencing row | retention |
|---|---|---|
| `CASCADE` | deleted | proceeds |
| `SET NULL` / `SET DEFAULT` | kept, reference severed | proceeds |
| `NO ACTION` (the default) / `RESTRICT` | untouched | **blocked**, with PostgreSQL's own error |

pgpm issues a `DELETE` for exactly the crossing keys and lets PostgreSQL apply whatever was declared;
the work is bounded by the crossing, not by the partition or the referencing table. A blocked retirement
logs `fail_retain_crossing` carrying the constraint's own error, counts in `status().retain_drop_failures`,
and leaves the partition whole. That is not a pgpm limitation to work around: a `NO ACTION` foreign key is
a statement that these rows must not disappear while something points at them, and retention honouring it
is the constraint doing its job. Change the referential action, or remove the referencing rows, if you
meant otherwise.

Successful crossings are logged `retain_crossing` with the key and row counts, because this is the one
point where retiring a partition writes to a table you did not hand to pgpm.

## Secondary indexes

`transmute` copies the old table's non-unique secondary indexes onto the parent as partitioned indexes
(reusing the monolith's existing index, no rebuild), so they propagate to every partition, including the
fine children that regrain creates. A unique secondary index is carried the same way **when its key
includes the partition key** (so global uniqueness is genuinely preserved). One whose key excludes the
partition key cannot be a partitioned unique index, so `transmute` **refuses** rather than silently
dropping the guarantee: add the partition key to that index, or drop it, then re-transmute.

## How the conversion avoids a rewrite

Two facts about Postgres drive the design:

1. You cannot convert a table to partitioned in place, so transmute renames the live table, creates a
   partitioned parent under the original name, and attaches the old table as a bounded child. No rows
   move; the app sees no change.
2. Attaching a partition whose rows are not certified in range forces a scan under `ACCESS EXCLUSIVE`,
   which would block the workload.

pgpm sidesteps #2 with a scan-skip attach: certify the bound with a validated `CHECK` *before* the attach,
so the attach itself is metadata-only. Certifying it is `VALIDATE CONSTRAINT`, whose own
`SHARE UPDATE EXCLUSIVE` lock blocks nobody. Today it does not run alone, though: it shares a transaction
with the `ALTER TABLE` that adds the constraint, so that statement's `ACCESS EXCLUSIVE` is still held while
it scans, and the table is locked throughout. See
[The cutover moves no rows](#the-cutover-moves-no-rows) for what to size.

```sql
ADD CONSTRAINT b CHECK (control >= lo AND control < hi) NOT VALID  -- catalog only, instant, ACCESS EXCLUSIVE
VALIDATE CONSTRAINT b                                              -- the scan, wants only SHARE UPDATE EXCLUSIVE
ATTACH PARTITION ...                                               -- scan skipped, metadata-only
```

The monolith attaches this way at transmute (one scan of the original). `obtain`'s forward
partitions need no scan at all, because the `DEFAULT` they would be checked against is empty (this is why
keeping the `DEFAULT` empty matters). Regrain's fine children are born with their bound `CHECK`, so they
too attach metadata-only. The one rule that keeps it safe: never certify a range that is still receiving
writes -- the monolith covers up to `B` (a boundary above the frontier) precisely so the current interval
lives inside it, and regrain only touches frozen children.

## Read consistency

There is no read gap. A `SELECT` against the parent always sees every row.

This used to be the one correctness caveat worth understanding. The paced **drain** evacuated a stray by
`DELETE`ing it from the `DEFAULT` and re-`INSERT`ing it into a not-yet-attached child across separate
transactions, and since a query against the parent only scans attached partitions, a read issued mid-move
undercounted the range being moved. `pgpm.snapshot()` existed to paper over exactly that, by unioning the
in-flight children back into a read of the parent.

Both are gone. The drain and the `DEFAULT` were removed, and **regrain never opened the gap**: it *copies*
and never deletes from the source, so the coarse child stays whole and attached until one atomic swap and
every row is visible through the parent the entire time. Its in-flight copies are duplicates of rows still
in the monolith, so the parent's count is already complete.

## WAL and checkpoint sizing

Moving rows rewrites them (a cross-partition `DELETE` + `INSERT`), so a **regrain** is a burst of WAL
concentrated over the regrain window (the steady-state drain is tiny by comparison). If
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
  outruns what the checkpointer can sustain, and auto-regrain spreads the regrain across ticks so the WAL
  burst becomes a trickle. The two compose: raise `max_wal_size` when you can, keep adaptive as a safety
  net.

## Operations and troubleshooting

For step-by-step procedures when an alert fires, see the [runbook](runbook.md). Quick reference:

- **Pause / resume.** `select pgpm.pause('public.events');` / `select pgpm.resume('public.events');`. A
  paused table is registered but untouched by `maintain` (you can still drive `obtain`/`regrain` by hand).
- **A write is refused with `no partition of relation ... found for row`.** The value is outside the
  forward grid. Check `status().newest_bound`: if it has stopped advancing, maintenance has stalled;
  otherwise the write is further ahead than `config.obtain x partition_step` reaches. See the
  [runbook](runbook.md) for both cases.
- **History is not being split.** `status().history_unregrained` is true and you want fine partitions:
  enable auto-regrain (`set_regrain`) or run `regrain_history` by hand once the monolith has frozen.
- **Re-transmuting a table fails with an "orphan" error.** An interrupted regrain creates child
  partitions as standalone tables before attaching them; an un-attached child survives a `DROP TABLE
  <parent> CASCADE`. `transmute` detects a leftover and refuses up front; drop the named orphan and retry.

## Caveats and v1 scope

- **Dimensions:** `time` (interval step; whole-month or fixed-duration; mixing rejected), `id`
  (bigint/numeric step), `uuidv7`/ULID-as-uuid (time grid, uuid bounds). `float`/`double` rejected; other
  encodings partition on a companion column.
- **Monotonicity is the precondition.** UUIDv7/ULID are ms-resolution monotonic with a small
  clock-skew/late-arrival window; the don't-close-until-frontier-past rule plus the `DEFAULT` net absorb
  stragglers. Arbitrary backdated keys break it.
- **The cutover locks the table for one read-only scan:** no row movement, no PK rewrite, no index
  rebuild, but reads and writes both wait while the original is scanned once. The wait scales with row
  count, so size a window from it (see [The cutover moves no rows](#the-cutover-moves-no-rows)).
- **The history starts coarse.** It is one monolith partition until regrained; until then, pruning and
  fine-grained retention are suspended over its span. A coarse monolith is a valid permanent state.
- **Regrain needs transient disk** (about 2x the span being regrained) and copies the rows; both the
  synchronous and the paced auto-regrain path are gap-free (the source stays whole and attached until the
  atomic swap, which transiently drops and re-adds any incoming FK within one transaction).
- **There is no `DEFAULT`**: a write outside the forward grid is refused rather than parked.
- **Retain uses plain `DROP`** (a brief lock); retention over coarse history waits on regrain.
- **Unique secondary indexes** are carried when their key includes the partition key; otherwise refused.
- **The key is never rewritten;** a primary key or unique constraint that includes the control column is
  reused in place, and a keyless table is partitioned keyless. The control column must be `NOT NULL`.
- **Incoming foreign keys** are refused by default, or preserved (dropped for the conversion, re-added
  against the new parent) with `p_incoming_fks => 'preserve'`.
- **Mid-move reads undercount on the paced paths; writes to moved rows no-op.** Inherent to an online
  move; see [Read consistency](#read-consistency). The synchronous paths avoid
  it entirely.
- Tested on PostgreSQL **15, 16, 17, and 18**. Boundaries align to the database timezone (UTC by default).
