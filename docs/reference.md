# Reference

Every public function and catalog object in `pg_partition_magician`, described **as built**. The schema
is `pgpm`. This is the authoritative surface; the [user guide](guide.md) explains the concepts and how the
pieces fit.

The mental model in one breath: `transmute` converts a live table into a native `RANGE`-partitioned one
by renaming the original aside and attaching it, with **zero row movement**, as one bounded **monolith**
child (covering `[grid_floor(min), B)`), and laying down a **forward grid** of real, bounded partitions
above it. There is no `DEFAULT`: a write no partition covers is refused. Going forward, `obtain` keeps the
grid ahead of the write frontier, `retain` drops whole partitions past a policy, and `regrain` splits the
coarse monolith into finer partitions on demand. `maintain` is the one procedure `pg_cron` runs.

Conventions used below: `p_parent` is the partitioned parent (a `regclass`); a native grid value is a
`timestamptz` for the `time` and `uuidv7` kinds and a `numeric` for the `id` kind; "the frontier" is
`now()` for `time` and `max(control)` for `id`/`uuidv7`.

## Conversion

### `transmute` (time / uuidv7 grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false
) returns regclass
```

Converts `p_parent` into a partitioned table and registers it. The control column's type selects
the kind: a `uuid` column is treated as **uuidv7** (time-ordered; ULIDs stored as `uuid` included), and a
`timestamptz`/`timestamp`/`date` column is **time**. Returns the new partitioned parent (same name as the
original).

The cutover moves no rows: it validates a bound on the live table (one read-only scan), then in a
metadata-only step renames the original to a coarse-child name, creates the
partitioned parent, attaches the original as the bounded **monolith** child via the validated `CHECK`
(scan-skipping), and builds the forward grid. The table registers **paused**; nothing happens
until you `resume` it and maintenance runs.

The new parent also takes over everything `CREATE TABLE ... LIKE` does not carry: the **owner**, table and
**column-level grants**, **row level security** (both `ENABLE` and `FORCE`), every **policy**, table and
column **comments**, and **row triggers**. All of it is captured before the rename and re-applied inside
the same transaction as the cutover, so the parent is never reachable without its policies. Partitions
minted later, by `obtain` or a regrain, are given the parent's owner too rather than being
owned by whichever role runs maintenance.

Policies live on the parent, and only on the parent: a parent policy governs parent-routed reads into a
partition, and reaching a partition directly needs grants that live on the parent anyway.

One shape is refused rather than carried: a `FOR EACH ROW` trigger with a transition table
(`REFERENCING OLD/NEW TABLE`), which PostgreSQL does not permit on a partitioned table. Rewrite it as a
statement trigger, which can carry a transition table, or drop it. Foreign keys are separate; see
`p_incoming_fks` below and the outgoing-FK limit. An identity column is carried onto the parent and its sequence
advanced to the greater of `max(id) + 1` and the original sequence's own next value, so auto-generated ids
never collide and never re-issue a value the sequence had already moved past (`untransmute` restores it the
same way).

Parameters:

- `p_control` -- the partition-key column. It **must be `NOT NULL`** (a partition key cannot be null;
  `pgpm` never scans to enforce it). A key is not required: if a **primary key or unique constraint**
  includes the control column, `pgpm` reuses it in place and never rewrites it; otherwise the table is
  partitioned **keyless** (no key synthesized). A key that *excludes* the control column is refused (no
  rewrite), as is a *bare* unique index (promote it to a constraint first). Note: `regrain` is unavailable
  on a keyless monolith, so its history stays as one coarse child unless a key is added before transmute.
- `p_interval` -- the grid width (`interval '1 day'`, `'1 month'`, `'1 year'`, ...). Cast a bare literal:
  `interval '1 month'` (it disambiguates from the `bigint` overload).
- `p_obtain` -- how many partitions to keep ahead of the frontier.
- `p_retain` -- drop partitions older than this `interval`; `null` keeps everything.
- `p_regrain_batch` -- rows per regrain COPY microbatch.
- `p_anchor` -- the grid origin the boundaries align to.
- `p_paused` -- register paused (the default); `false` goes live immediately.
- `p_incoming_fks` -- `'error'` (refuse if any incoming FK exists), `'drop'` (drop them), or `'preserve'`
  (drop for the conversion and re-add against the new parent once the table is quiescent).
- `p_force_uuidv7` -- skip the uuidv7 plausibility refusal (see below).

Refuses up front (leaving the table untouched) when: a key (primary key or unique constraint) exists but
excludes `p_control`, or only a *bare* unique index includes it (promote it to a constraint first); the
control column is `float`/`double` (imprecise boundaries); a `time`-kind control column
is not a timestamp/date, or a `uuidv7` control is not `uuid`; a `uuid` control samples as overwhelmingly
random (UUIDv4) and `p_force_uuidv7` is not set; a non-PK `UNIQUE` secondary index does not include the
partition key (global uniqueness could not be enforced); an incoming FK exists and `p_incoming_fks` is
`'error'`; or a standalone table matching the child-partition naming already exists (an orphan from an
interrupted run).

```sql
call pgpm.transmute('public.events', 'created_at', interval '1 month',
                      p_obtain => 7, p_retain => interval '90 days');
```

### `transmute` (integer / id grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 30, p_retain bigint default null,
  p_regrain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
) returns regclass
```

The **id** overload, for `int`/`bigint`/`numeric` keys (including Snowflake-style ids). Identical to the
time overload except the grid width is a `bigint` `p_step`, `p_retain` is a `bigint` count of ids, and
`p_anchor` is a `bigint`. There is no `p_force_uuidv7`.

```sql
call pgpm.transmute('public.events', 'id', 10000000, p_obtain => 2);
```

### `untransmute`

```sql
pgpm.untransmute(p_parent regclass) returns regclass
```

Reverses a `transmute`, returning the restored ordinary table. It is a **clean, metadata-only reverse
while the monolith is still intact and holds the whole table**: it detaches the monolith, drops the
childless parent (cascading any empty forward partitions), renames the monolith
back, restores identity and any preserved incoming FKs, and clears `pgpm` state. The monolith is the
attached partition with the smallest `lo`.

It is a **one-way door** once any row lives outside the monolith's range -- a forward partition after the
frontier crosses `B`, or finer children from a regraining -- because a
metadata-only reverse would lose those rows. (Tier-2 fold-back and Tier-3 merge are not built.)

## Migrating from TimescaleDB (`from_hypertable`)

An **optional add-on** (`pgpm_hypertable/install.sql`) for migrating a TimescaleDB **Apache-edition** hypertable
to a `pgpm`-managed native `RANGE` partition set. Load it on top of the core, only in a database where the
`timescaledb` extension exists (the core's lone runtime dependency stays `pg_cron`). It un-hypertables the
table by a full **online copy** into a plain table under the original name, then hands off to `transmute`, so
it stays version- and catalog-agnostic, which is what the deprecated Apache builds need. Verified on
TimescaleDB 2.9.1 and 2.16.1 (PG15).

The procedures `COMMIT` (per chunk during the copy, and at the swap), so they must be invoked at the top
level (a plain `CALL`, never inside a surrounding transaction or an atomic block).

Scope and caveats:

- A single time/`RANGE` dimension. **Continuous aggregates** and **space partitioning** (more than one
  dimension) are refused up front.
- The control column's key is whatever `transmute` reuses: a primary key or unique constraint that includes
  it, else **keyless** (the common hypertable shape, since `create_hypertable` makes the time column
  `NOT NULL` but adds no key). Identity columns, generated columns, `CHECK` constraints, defaults, and
  `NOT NULL` are all preserved (see `transmute`).
- The copy is **online** (the source serves traffic throughout), and so is the index rebuild: the
  destination's primary key and secondary indexes are built on the private copy **before** the cutover takes
  its lock. The cutover's `ACCESS EXCLUSIVE` window is therefore **brief and metadata-bound** -- it catches up
  the delta, swaps the table in, and *adopts* the pre-built indexes (`USING INDEX`); it does not rebuild them
  under the lock, so the blocking window does not grow with table size the way an under-lock rebuild would.
  The catch-up backlog is also drained **online, in micro-batches, before the lock** -- the tracked change
  delta (`from_hypertable_drain_delta`, with `p_track_changes`) or the appended-rows tail
  (`from_hypertable_drain_appends`, the default append-only path) -- so the window does not grow with the
  accumulated lag either.
- The copy writes a **full second table**, so the migration transiently needs roughly the source's current
  size in extra disk until cutover drops the old hypertable. `from_hypertable_preflight` raises a `NOTICE`
  with the estimate; `from_hypertable_disk_estimate` returns it for sizing a volume ahead of time.
- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, but retention over
  the unregrained **monolith is dormant** until you `regrain` it (`retain` only drops attached fine partitions),
  and `regrain` is unavailable on a keyless monolith. So a keyless migration that relied on `drop_chunks` will
  not reclaim disk until a key is added and the monolith is regrained.

### `from_hypertable`

```sql
pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false, p_predrain boolean default true
)
```

The one-shot driver: runs `from_hypertable_copy` then `from_hypertable_cutover` back to back. Use it when the
migration does not need to interleave application writes between the phases. `p_interval` and the
`p_obtain`/`p_retain`/`p_anchor`/`p_paused` parameters pass straight through to `transmute`; `p_drain_batch` is this module's own
to `transmute` (see there); `p_control` is the time column; `p_track_changes` and `p_predrain` are described
under `from_hypertable_copy` and `from_hypertable_cutover`. When `p_retain` is left `null`, the source's
`drop_chunks` policy interval (if any) is carried in.

```sql
call pgpm.from_hypertable('public.metrics', 'ts', interval '1 day', p_paused => false);
```

### `from_hypertable_copy`

```sql
pgpm.from_hypertable_copy(p_hypertable regclass, p_control name, p_track_changes boolean default false)
```

Phase 1: build the plain destination (`<rel>_pgpm_dest`) and bulk-copy the existing chunks into it online, one
chunk-range per transaction, clustered by the control column. The source keeps serving traffic. Run this, let
the workload continue, then run `from_hypertable_cutover` when ready.

- `p_track_changes` -- capture in-flight **updates and deletes**, not just appends. When `false` (the
  default), the cutover catches up **append-only** (rows whose control column is past the copy watermark),
  which is correct for append-only workloads but **silently loses updates and deletes** to already-copied
  rows. That append-only tail is pre-drained online before the lock too
  (`from_hypertable_drain_appends`, run automatically by the cutover). When `true`, the copy installs an
  `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values (plus a monotonic `pgpm_seq` ordering column) to a `<rel>_pgpm_delta` table. That
  backlog is reconciled **online, in micro-batches, before the cutover** (`from_hypertable_drain_delta`, run
  automatically by the cutover), and the cutover applies only the residual under the lock. Reconciliation is
  by the key `transmute` reuses (a primary key or unique constraint), so `p_track_changes => true` is
  **refused on a keyless table** (no key to reconcile by) and on a key with a **nullable (non-control)
  column** (a `NULL` key component can never be reconciled, so the change would be lost). Set it for any
  workload that updates or deletes rows during the migration window.

### `from_hypertable_drain_delta` / `from_hypertable_drain_delta_step`

```sql
pgpm.from_hypertable_drain_delta(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
)
pgpm.from_hypertable_drain_delta_step(p_hypertable regclass, p_control name, p_batch int default 5000)
  returns bigint
```

Reconcile the `p_track_changes` delta **online, while the source stays live**, so the cutover's lock applies
only a tiny residual instead of the whole online-copy backlog. The cutover runs this
automatically (`p_predrain`), but you can also drive it directly during a long two-phase window: after
`from_hypertable_copy`, call it repeatedly while the application keeps writing, then `from_hypertable_cutover`.

The reconcile is idempotent and order-independent per key (delete the key's copied row from the destination,
re-insert its current source row), which is what makes incremental draining safe. Each batch
**delete-RETURNS** its rows from the delta as the authority and reconciles exactly those keys against the live
source, so a change is never deleted-without-applying; the source read is bounded per batch to the touched
control range for chunk exclusion. The driver mirrors `drain`'s `_step` + loop shape and **commits per batch**
(so WAL recycles); `_step` does one batch (no commit, returns the keys it cleared). The per-batch delete uses
the reused-key index that `from_hypertable_copy` builds once on the private destination -- the
same index the cutover later *adopts* (`USING INDEX`), so no throwaway index is built or dropped.

- `p_batch` -- micro-batch size (delta rows processed per batch, bounded by a `pgpm_seq` watermark).
- `p_threshold` -- stop once the residual is at/below this many delta rows (`0` = drain to empty). Under
  sustained write load, stop a little short and let the under-lock cutover pass finish the rest.
- `p_max_iter` -- convergence budget. If the workload dirties keys faster than the drain clears them, the
  driver raises a loud, actionable error -- unless `p_best_effort`, in which case it returns so the caller
  (the cutover) can take the lock and finish the residual under it.

### `from_hypertable_drain_appends` / `from_hypertable_drain_appends_step`

```sql
pgpm.from_hypertable_drain_appends(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
)
pgpm.from_hypertable_drain_appends_step(p_hypertable regclass, p_control name, p_batch int, p_watermark text)
  returns text
```

The **append-only** counterpart of `from_hypertable_drain_delta`, for the default
(non-`p_track_changes`) path: copy the rows appended past the copy watermark **online, while the source stays
live**, so the cutover's lock applies only the final tail. The cutover runs it automatically (`p_predrain`)
for the non-tracking path; you can also drive it directly during a long two-phase window.

It is purely additive (append-only means already-copied rows never change), so unlike the delta drain it
needs no delta, no reconcile, no key, and no destination index, and works on a **keyless** hypertable. Each
batch copies the rows in `(watermark, hi]` where `hi` is the control value `p_batch` rows past the watermark
(inclusive of ties at `hi`, so the next batch's strict `>` skips none), as literal bounds for chunk exclusion;
it then advances the watermark to `hi`. The driver carries the watermark across batches (read once up front,
never re-scanning the destination for `max()`) and **commits per batch**; `_step` does one batch (no commit,
returns the advanced watermark). `p_threshold`, `p_max_iter`, and `p_best_effort` behave as in
`from_hypertable_drain_delta`. Assumes the append-only contract (no updates/deletes to copied rows), exactly
as the under-lock catch-up does; use `p_track_changes` for update/delete workloads.

### `from_hypertable_cutover`

```sql
pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_predrain boolean default true
)
```

Phase 2: the cutover. When `p_predrain` is `true` (the default), it first **pre-drains the catch-up backlog
online** (best-effort, using `p_drain_batch` as the batch size and residual threshold) -- the change delta
(`from_hypertable_drain_delta`) when tracking is on, else the appended-rows tail
(`from_hypertable_drain_appends`) -- so only a tiny residual is left for the lock. Then it **pre-builds the
destination's primary key and secondary indexes online** (on the private copy, before any lock -- this is the
O(rows) work, deliberately kept out of the blocking window). For the append-only path the catch-up watermark
(`max(control)` on the destination) is also read here, before the lock, so an `O(rows)` `max()` seqscan on a
keyless destination is not in the blocking window.
Then it takes a **brief, metadata-only `ACCESS EXCLUSIVE` window**: catch up the writes that arrived during
the copy (append-only, or a full delta replay when `from_hypertable_copy` ran with `p_track_changes => true`
-- auto-detected via the delta table, so the two phases cannot disagree), drop the hypertable, rename the copy
into place, **adopt** the pre-built unique indexes as the original `PRIMARY KEY`/`UNIQUE` constraints
(`ALTER TABLE ... USING INDEX`, metadata-only) and rename the secondary indexes back to their original names,
re-add the identity columns (which `CREATE TABLE LIKE` does not carry), then hand off to `transmute`. Because
the index builds happen before the lock, the blocking window is bounded by the catch-up + metadata, not by the
table size. It also preserves each identity
sequence's exact position: `transmute` seeds past `max(id)`, but if the source sequence was further ahead
(gaps from rollbacks, caching, or deleted high rows) the migrated sequence is advanced to the source's next
value so those ids are not re-issued. The swap is one transaction: it
commits whole or rolls back whole, leaving the source intact on any failure. Requires `from_hypertable_copy`
to have run (the destination must exist). Parameters past `p_interval` pass through to `transmute`.

```sql
call pgpm.from_hypertable_copy('public.metrics', 'ts', p_track_changes => true);
-- ... the application keeps writing (inserts, updates, deletes) ...
call pgpm.from_hypertable_cutover('public.metrics', 'ts', interval '1 day', p_paused => false);
```

### `from_hypertable_preflight`

```sql
pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name) returns void
```

The refusal gate, factored out so you can dry-run it inside a transaction. Raises a
`pg_partition_magician:`-prefixed error when the hypertable cannot be migrated by this version, and returns
normally otherwise. **Refuses** when: the `timescaledb` extension is absent; `p_hypertable` is not a
hypertable; it has one or more **continuous aggregates** (no native-partition equivalent, and dropping them is
data-destructive); it has more than one **dimension** (space partitioning); the `p_control` column does not
exist; an **outgoing** foreign key is `NOT VALID`; or an **incoming** foreign key references anything other
than the key pgpm will reuse. On success it raises a `NOTICE` estimating the transient extra disk the migration needs (see
`from_hypertable_disk_estimate`) and a rough copy-time ETA (see `from_hypertable_time_estimate`). Both
`from_hypertable_copy` and `from_hypertable` call it first.

#### Foreign keys

Both directions are carried across the migration.

An **outgoing** key (the migrated table referencing another table) is replayed verbatim on the private copy
during `from_hypertable_copy` as `NOT VALID`, validated there in its own transaction, and re-added at the new
parent after the handoff. Validating on the copy keeps the `O(rows)` scan off the cutover's lock, and because
the copy becomes the monolith child with an already-validated key, the parent-level add is metadata-only.
Logged `from_hypertable_carry_fk` and `from_hypertable_adopt_fk`.

An **incoming** key (another table referencing the migrated one) is captured and dropped in the cutover --
that is what allows the source hypertable to be dropped, since such a key puts a constraint on every chunk --
then re-added against the new parent afterwards through `pgpm.dropped_fk`, so
[`restore_incoming_fks`](#restore_incoming_fks) and [`validate_incoming_fks`](#validate_incoming_fks) do the
re-add and the validation with their usual reporting. Referential integrity is therefore **off on the
referencing table** from the cutover's drop until that re-add, a window bounded by the swap plus one
`transmute` and surfaced by `status().fks_suspended`. It cannot be closed by re-adding inside the cutover,
because `transmute` refuses a table that still carries an incoming key.

`from_hypertable_preflight` refuses an incoming key that references anything other than the key pgpm will
reuse, before any copying happens.

### `from_hypertable_disk_estimate`

```sql
pgpm.from_hypertable_disk_estimate(p_hypertable regclass) returns bigint
```

The approximate extra disk the online migration needs: the source hypertable's current on-disk size (heap,
indexes, and toast summed across all chunks) in bytes. The copy writes a full second table, so free roughly
this much until cutover drops the old hypertable and the space is reclaimed. `preflight` reports it as a
`NOTICE`; call this directly (with `pg_size_pretty`) to size a volume before starting.

### `from_hypertable_time_estimate`

```sql
pgpm.from_hypertable_time_estimate(p_hypertable regclass, p_copy_mibps numeric default null) returns interval
```

A **rough** estimate of the online-copy duration, the dominant cost of migrating a hypertable. (Converting a
plain table with `transmute` is metadata-only and takes seconds regardless of size; a hypertable's rows must
be physically copied out, which is O(rows).) It divides `from_hypertable_disk_estimate` by an assumed
effective copy throughput. `p_copy_mibps` overrides that throughput (MiB/s of logical data); when `null` it is
chosen by comparing the estimated size to `effective_cache_size` (cache-resident vs disk-bound). The default
rates (~40 MiB/s cache-resident, ~16 MiB/s disk-bound) are order-of-magnitude figures measured on a 2XL on
gp3 and scale with RAM/IOPS/throughput. It covers **only the copy**; the (online) index build and the brief
cutover are additional. `preflight` reports it as a `NOTICE`.

### Performance: how long, and how to speed it up

The migration time is dominated by two O(rows) but **online** (non-blocking) phases, the chunk-by-chunk copy and
the index pre-build, plus a brief metadata cutover. To go faster (with the limits):

- **More RAM** is the single biggest lever when the working set is near RAM size: a cache-resident copy runs
  several times faster than a disk-bound one (measured ~2.5x). Many times past RAM you are firmly I/O-bound
  and RAM stops helping.
- **More disk IOPS / throughput** (gp3 to io2, higher MiB/s): the copy reads the source chunks and writes the
  destination (~2x the bytes over the disk), so disk throughput caps the disk-bound rate, bounded by the
  instance's sustained-throughput ceiling.
- **Raise `max_wal_size`** for the migration. The copy and index build are write-heavy, and on a stock
  `max_wal_size` they outrun it and force checkpoints that throttle progress (at-scale runs showed dozens of
  forced checkpoints and long checkpoint write times). A larger `max_wal_size` (and `checkpoint_timeout`)
  removes that stall.
- **`maintenance_work_mem`** and **`max_parallel_maintenance_workers`** speed the index pre-build.

Hard floors: every byte is read and written once (the copy); the migration transiently needs roughly 2x the
source size in disk until cutover drops the old hypertable; and the cutover's metadata window cannot go below
the delta catch-up.

## Maintenance steps

`maintain` orchestrates these; you can also call them by hand.

### `obtain`

```sql
pgpm.obtain(p_parent regclass) returns int
```

Creates empty partitions ahead of the frontier so live writes always land in a real partition, keeping
`config.obtain` of them ready, and returns how many it created. Pure catalog work: the partitions are
created empty, so nothing is scanned and nothing is moved. It skips any candidate range that overlaps an
existing attached partition, for example the monolith, which covers the current interval.

It stops early, returning what it built, when the next grid boundary cannot be expressed: a `uuidv7` grid
ends at the last instant a 48-bit millisecond prefix can carry, `10889-08-02 05:31:50.65504+00`.

This is the only thing standing between the workload and a write with nowhere to go, since a row outside
the grid is refused rather than parked. `config.obtain x partition_step` is therefore both the slack if
maintenance stalls and a ceiling on how far ahead an application may write.

A procedure, not a function, because of those commits. It takes an advisory lock per parent, so a second
concurrent `obtain` defers instead of interfering, and it reports failures through `p_deferred` rather
than raising: `maintain` cannot wrap it in an exception handler, since transaction control is illegal
below one.

### `retain`

```sql
pgpm.retain(p_parent regclass) returns int
```

Drops every partition whose whole range is older than the retention horizon (`config.retain`), returning
the count dropped. A coarse partition that merely straddles the horizon is **not** dropped, so retention
is suspended over un-regrained coarse history until `regrain` splits it (or `regrain` reclaims the aged
sub-ranges directly). `null` retention drops nothing.

`config.retain_batch` caps how many eligible partitions one call will **attempt** (write-block ensure,
archive-coverage check, drop), oldest first; the rest of the backlog waits for later calls -- on the
scheduled path, later `maintain` ticks, each its own transaction. `null` (the default) is unbounded. The
cap bounds attempts, not successes: an unexpected drop failure at the head of the backlog defers
everything behind it until it clears (the wedge shows as a flat `status().retain_backlog` with climbing
`retain_drop_failures`). A child whose chunked archiving simply hasn't caught up yet is *not* a wedge --
`retain_drop_failures` stays at zero for that; see [`retire`](#retire).

`retain()` is a loop over [`retire`](#retire): it picks the eligible set and `retire` carries the
per-partition protocol.

### `retire`

```sql
pgpm.retire(p_parent regclass, p_child name) returns boolean
```

The sanctioned single-partition drop: `retain()`'s per-partition body, public and claim-guarded, for an
external assistant (e.g. an archive-then-drop scanner) -- or several cooperating ones -- to drive
retirement directly. It claims the `pgpm.part` row, ensures the child is write-blocked
(`pgpm._install_write_block`, idempotent), checks `pgpm._archive_fully_covered`, and only then `DROP`s, deletes the catalog row, and logs `retain_drop`. Returns `true`
iff this call dropped the partition.

`retire` never widens what retention may drop -- a caller only picks **which** eligible partition and
**when**. It refuses (raises) an unmanaged table, a table with no retention policy (`config.retain` is
null), a partition whose range is not entirely at/below the retention horizon, and an in-flight
(unattached) regrain copy-child.

It returns `false`, without side effects and without logging anything, in three normal, retryable
situations: the `pgpm.part` row is absent (already retired by another actor), it's claimed by a
concurrent transaction (`FOR UPDATE SKIP LOCKED`, so each partition has exactly one owner at a time), or
the partition is write-blocked but not yet `pgpm._archive_fully_covered` -- chunked archiving (from
simply hasn't caught up yet. Only a genuinely unexpected failure in the `DROP` itself is
logged (`fail_retain_drop`) and returns `false`.

#### Retiring a partition an incoming FK references

If any foreign key references the managed parent, a bare `DROP` is refused on a pure catalog dependency
regardless of whether any row actually references the aged range, so `retire` detaches first.
The detach must be `CONCURRENTLY`, which PostgreSQL will not execute from a function, so `retire`
**dispatches** it: it rewrites the standing `pgpm_detach` cron job's command and returns `false`, and a
later call finds the partition detached and completes the `DROP`. Retiring a referenced partition
therefore takes at least two calls and requires [`pgpm.schedule`](#schedule) to have been run.

The sequence, per partition:

1. If a live row references a doomed one, `DELETE` exactly those keys from the parent, so PostgreSQL
   applies the referential action the operator declared. `CASCADE`, `SET NULL` and `SET DEFAULT` proceed;
   `NO ACTION` and `RESTRICT` refuse, and the refusal is logged `fail_retain_crossing` with the
   constraint's own error, leaving the partition intact. A successful crossing is logged `retain_crossing`.
2. Set `pgpm.part.retiring_at` and point `pgpm_detach` at this partition's concurrent detach, in one
   transaction, logged `retain_detach`. With no such job, `fail_retain_detach` is logged instead.
3. On a later call, with the partition detached, `DROP` it, delete the catalog row, log `retain_drop`, and
   return the cron job to idle.

`fail_retain_crossing` and `fail_retain_detach` both count in `status().retain_drop_failures`; in-flight
detaches show in `status().retain_detaching`. A partition that is detached but carries no `retiring_at` was
detached by something other than pgpm, and `retire` refuses to drop it.

### `_detach_reap`

```sql
pgpm._detach_reap() returns int
```

Finishes any concurrent detach whose session died part-way, and returns how many it finished.
`maintain_all` calls it before the per-parent loop, alongside `_transmute_reap`, because it is the most
urgent thing in a tick: a backend killed during a concurrent detach's *wait* phase leaves the partition
flagged `pg_inherits.inhdetachpending` with its rows **already invisible through the parent**, so rows
appear to vanish from the table while the partition is neither detached nor dropped. `ALTER TABLE ...
DETACH PARTITION ... FINALIZE` completes it, logged `detach_reap`.

It finalizes unconditionally (a pending detach is never a state to leave sitting) but drops nothing:
`retire` completes pgpm's own retirements on the normal path, and an operator's hand-run detach that was
interrupted is finished and then left alone.

### `regrain`

```sql
pgpm.regrain(p_parent regclass, p_child name, p_target_step text default null) returns int
```

Splits one **frozen** coarse child `p_child` into finer children of width `p_target_step` (default
`config.partition_step`), returning the number of fine children created. It **copies** rows into standalone
children in budget-sized microbatches, then swaps them in for the coarse child and drops that source whole,
rows and all. It never deletes from the source, which is what keeps a read of the parent from ever being
short mid-regrain; the fine children are insert-only, so the product has no bloat. The whole call runs in
one transaction, so it is **atomic and gap-free**. Retention-aware: a sub-range entirely below the horizon
is reclaimed, never materialized. Refuses (as an exception) when the child is not frozen, the target step
does not subdivide it, or another regrain is already in flight on the same parent.

Only one regrain runs per parent at a time. `config.regrain_cursor` and the change-capture delta are both
per parent, so a second concurrent regrain is refused rather than allowed to reset the first one's cursor
and discard its captured changes.

A child whose range is exactly one grid step wide carries the plain `_p<lo>` name, which is also what its
own first fine sub-range would be called. Regrain renames such a child to its explicit-range form
(`_p<lo>_to_<hi>`) before splitting it, logged as `regrain_rename`, so the sub-range names are free. The
rename is metadata-only, the child is dropped at the swap anyway, and `pgpm.part` is updated with it, so
the only visible effect is the transitional name. Anything driving a regrain across ticks by hand should
re-read the child name from `pgpm.part` rather than assuming it; `regrain`, `regrain_history` and
auto-regrain all do.

```sql
-- split the monolith into the configured fine granularity, once the frontier has passed it
select pgpm.regrain_history('public.events');
```

### `regrain_step`

```sql
pgpm.regrain_step(p_parent regclass, p_child name, p_target_step text default null, p_batch int default null)
  returns text
```

One resumable microbatch of `regrain`: it **copies** (never deletes) a within-horizon sub-range's next
budget-sized batch into its fine child, and performs the atomic swap once the cursor
(`config.regrain_cursor`) reaches the coarse `hi`.

A **below-horizon** sub-range is handled one of two ways, depending on whether the table archives. With
`config.archive_fn` unset it is skipped, logged as `regrain_aged`, and discarded with the source at the
swap, since `retain` would drop those rows unconditionally the moment they became partitions. With
`archive_fn` set it is **materialized like any other sub-range**, because `retire` will not drop a
partition until archiving has fully covered it, so discarding it would destroy exactly the rows that gate
is protecting. Once materialized, the ordinary pipeline applies: `maintain` write-blocks it,
archives it, and `retire` drops it once covered. The cost is copying rows that are about to be dropped,
which is paid only on tables that archive. The
source stays whole and **attached** until that swap, so a read of the parent is never short. Returns
`prepared` (the first tick, which installs change capture and copies nothing), `reconciled:N`,
`copied:N`, `reconciling:N` (the swap is waiting for the captured backlog to clear), `swapped:K` (regrain
complete, K children attached), or a soft no-progress status: `active` (not frozen yet)
(a stray sits in the range), or `nosubdiv` (the step does not subdivide). This is the unit `maintain`
paces across ticks; because it copies, the cross-tick path opens **no** read gap. Its
one FK touch is the swap's `DETACH`, which transiently drops and re-adds any incoming FK within that
single transaction.

Committed DML against the source while a regrain is in flight is honoured. A trigger on the source records
changed keys into a per-parent delta table, and a reconcile pass treats the **source** as the authority for
each captured key, so a row inserted, deleted or updated mid-regrain is not lost, resurrected or reverted
by the swap. The reconcile is bounded by the same budget as the copy and takes the tick when there is work,
so a burst of DML paces itself rather than landing inside the swap. If writes outpace it the regrain stalls
at `reconciling:N` rather than swapping: the source stays attached, reads are unaffected, and no unbounded
work is done under the swap's lock.

Note the first tick therefore does no copying. A regrain that used to take N ticks now takes N + 1.

### `regrain_cancel`

```sql
pgpm.regrain_cancel(p_parent regclass) returns int
```

Stops an in-flight regrain and reclaims what it has built, returning the number of in-flight fine children
dropped. It removes change capture, clears the delta, drops every not-yet-attached copy, and resets
`config.regrain_cursor`. The parent is untouched: the source child still holds every row, so this costs the
copying work already done and nothing else.

The copies are **dropped, not kept**. Keeping them would let a later regrain resume from copies made before
the cancel, which were therefore never reconciled.

Abandoning a regrain without calling this (turning auto-regrain off mid-flight, say) is safe: `maintain`
sweeps orphaned capture each tick and logs `regrain_capture_orphan`. The verb exists so an operator can stop
one deliberately and get the disk back.

### `regrain_history`

```sql
pgpm.regrain_history(p_parent regclass, p_target_step text default null) returns int
```

Convenience: `regrain` the oldest coarse child (the monolith -- the smallest-`lo` attached partition) to
`p_target_step`. The hierarchical monolith to coarse to fine path is just repeated `regrain` calls with
chosen steps.

### `maintain`

```sql
call pgpm.maintain(p_parent regclass, inout p_status text default null)
```

The per-table tick: `obtain`, enforce write-blocks on every attached child against the retention
boundary, one chunked-archiving step, `retain`, restore any preserved FK once the table is quiescent,
and -- when auto-regrain is on (`config.regrain_to`) -- one `regrain_step` on the
oldest frozen coarse child. A no-op while paused. Every step is isolated in its own subtransaction
under a short `lock_timeout`, so it never blocks or deadlocks the live workload; a step that loses a
lock race is deferred and retried next tick.

A procedure, and each step commits before the next begins, so no step's locks outlive it. This
matters most for `obtain`, which takes `ACCESS EXCLUSIVE` on the parent when it creates a partition:
in a single-transaction tick that lock was held across the rest of the tick as well, stalling the whole table
(readers included) for as long as the drain batch took.

`p_status` reports a one-line summary, for example
`obtained=2 archived=1 dropped=0 drain=idle suspended_fk=0 restored_fk=0 regrain=copied:5000`. Call
it as `call pgpm.maintain('public.events')` and the summary comes back as a result row; from
PL/pgSQL, pass a variable to receive it.

Write-blocking: a child whose whole range sits at/below the retention horizon
(`_retain_boundary`, the same one `retain` itself uses) gets a `BEFORE INSERT OR UPDATE OR DELETE`
trigger the moment it becomes eligible, independent of whether or how it is archived -- a backdated
write into an eligible-but-not-yet-dropped range (including one a chunked archiver already covered)
is rejected rather than silently diverging the archive from what is live. Loosening `config.retain`
removes the trigger from a partition that becomes ineligible again. Write-blocked is one of
`retire()`'s drop preconditions (see [`retire`](#retire)).

Chunked archiving: `archived=N` counts how many chunks this tick recorded via
`pgpm._archive_step` -- see [Archive strategy contract](#archive-strategy-contract) for the
mechanism. It only ever considers a child the write-block step above has already protected, so it
always runs after write-blocking within the same tick. Archive coverage is `retire()`'s other drop
precondition.

### `maintain_all`

```sql
call pgpm.maintain_all()
```

A procedure that calls `maintain` for every managed table. This is what the scheduled job runs.

## Archive strategy contract

`config.archive_fn` is one archive strategy per managed table. `null` (the default) means strategy
`none` -- no archiving, a partition is
immediately drop-ready. Set it with `pgpm.set_archive_fn`:

```sql
select pgpm.set_archive_fn('public.events', 'myschema.my_archiver(regclass,name,text,text)'::regprocedure);
```

Casting the second argument to `regprocedure` validates that the function exists with exactly this
signature right away, not later when a maintenance tick tries to call it. A bare `null` (or calling
`pgpm.set_archive_fn` with no second argument) turns archiving back off.

The calling contract: `archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns
pgpm.archive_result`, where `pgpm.archive_result` is `(covered_hi text, rows_archived bigint, s3_key
text, etag text)`. `archive_fn` is expected to be **resumable**: called once per maintenance tick
against the same child, making bounded incremental progress and reporting how much of `[p_lo, p_hi)`
is now durably archived (`covered_hi`, which may be short of `p_hi`) and how many rows this one call
archived (`rows_archived`, `null` when nothing was actually archived) -- not to archive the whole
range in a single call. `s3_key`/`etag` are optional: a transport strategy that has an object-store
identifier to report (`pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet`) sets
them; a strategy with nothing object-store-shaped to name (`pgpm._archive_noop`, the `none`
strategy) leaves them `null`. This is the contract the byte-budget chunked archiver and the real S3
upload functions implement.

`pgpm._run_archive_strategy(p_parent, p_child, p_lo, p_hi)` is the dispatch stub: it looks up
`config.archive_fn` and calls it, or, for a `null` (`none`) strategy, returns `(p_hi, null)` directly
-- the whole requested range is trivially "already covered" since there was never anything to
protect against a drop. `pgpm._archive_noop` is a trivial built-in strategy (always reports the
whole requested range archived immediately, having actually counted the rows in it) that exists only
to exercise real dispatch in tests.

`retire()`'s drop precondition consults `pgpm._archive_fully_covered` (see
[`retire`](#retire)), which in turn is driven by `_run_archive_strategy` via `pgpm._archive_step`
below.

### Byte-budget chunked archiving

`pgpm.maintain()`'s per-tick archiving step (`archived=N` in its summary) is the
built-in way to drive the contract above without hand-writing a resumable `archive_fn`. It ports
`pgpm_archive`'s own byte-budget chunker (#213, #221) onto the contract, unchanged in intent: never
archive a whole large partition as one giant operation, chunk it instead.

- `config.archive_byte_budget` (default 8 MiB) and `config.archive_probe_sample` (default 1000) --
  the same two knobs the original chunker took as parameters -- estimate how many rows fit the
  budget via a sampled average row width.
- `pgpm.archive_ledger` (successor to `pgpm_archive`'s `archive.ledger`, same shape:
  `parent_table`, `lo`, `hi`, `child_name`, `s3_key`, `etag`, `rows_archived`, `archived_at`) records
  one row per chunk. `s3_key`/`etag` come straight from the `archive_fn` call's own
  `pgpm.archive_result` -- populated for a real transport strategy, still `null` for a
  strategy with nothing object-store-shaped to name (`pgpm._archive_noop`, the `none` strategy).
- `pgpm._next_archive_chunk(p_parent, p_child)` picks the next chunk **within one child's own
  `[lo, hi)`** -- resuming from wherever that child's ledger coverage left off, extended to the next
  distinct control value so a run of ties never splits across two chunks. Unlike the original
  (which picked ranges across the whole table, gated by the frontier and retention horizon
  directly), this is scoped to a single already-write-blocked child, because that gating is now the
  write-block trigger's job.
- `pgpm._archive_fully_covered(p_parent, p_child)` is true once the ledger's recorded ranges for
  that child reach its own `hi` (or the strategy is `none`) -- `retire()`'s archive-coverage drop
  precondition (see [`retire`](#retire)).
- `pgpm._archive_step(p_parent)`, called once per `maintain()` tick, is the orchestrator: for every
  attached child that **already has the write-block trigger installed** (checked directly, not
  re-derived from the boundary formula) and is not yet fully covered, it picks the next chunk, runs
  `_run_archive_strategy`, and records the result in `pgpm.archive_ledger`. A child without the
  trigger yet is never touched, however far past the byte budget's reach it sits.

### Real S3 archive strategies

`pgpm_archive` (the optional module, `pgpm_archive/install.sql`) ships two `archive_fn`-conforming
strategies: `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet` (both in the
`pgpm` schema, not `archive` -- they are `pgpm_core` contract implementations that happen to live in
this optional module). Set either via `pgpm.set_archive_fn`:

```sql
select pgpm.set_archive_fn('public.events', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
```

Both delegate to `archive._encode_upload_ndjson_single` / `archive._encode_upload_parquet` for the
actual transport -- the same encode/upload steps `archive.to_s3`/`archive.to_s3_parquet` (the
synchronous functions, called directly rather than through `archive_fn`) are built on, so the
encoded bytes and S3 semantics are identical; only the calling contract differs. Connection settings
(bucket, region, endpoint, prefix, vault key names, compression) still come from `archive.config`,
the same one config surface the synchronous functions use -- setting `archive_fn` this way needs no
second, independently configured surface. An `archive_fn` cannot issue `COMMIT`: it is a plain function
and PL/pgSQL forbids transaction control inside one regardless of call context. It does not need to
either, since `pgpm._next_archive_chunk` bounds every call to `config.archive_byte_budget` before
`archive_fn` ever runs.

## Scheduling

### `schedule`

```sql
pgpm.schedule(p_every text default '* * * * *') returns bigint
```

Creates (or replaces) the `pg_cron` job named `pgpm` that runs `call pgpm.maintain_all()` on the
`p_every` cron schedule in the current database, returning the job id. One job covers every managed table
and is idle while they are paused. Raises if `pg_cron` is not installed.

It also creates a second job, `pgpm_detach`, on the same schedule and **idle** (`select 1`). That one is
machinery for the referenced-partition path: `retire` rewrites its command in place when a partition an incoming foreign key
references needs `DETACH PARTITION ... CONCURRENTLY`, which PostgreSQL refuses to execute from a function,
and returns it to idle once the drop lands. One standing job is rewritten rather than one scheduled per
retirement, because `pg_cron` has no one-shot schedule. Retiring a referenced partition does not work
without it; if you scheduled pgpm before upgrading, re-run `pgpm.schedule()` once.

### `unschedule`

```sql
pgpm.unschedule() returns int
```

Removes the `pgpm` and `pgpm_detach` cron jobs (returns the number removed, so `2` for a fully scheduled
install; `0` if `pg_cron` is absent or nothing was scheduled).

## Control

### `forget_missing`

```sql
pgpm.forget_missing() returns table (parent_oid oid, partitions_forgotten int, orphan_tables text[])
```

Clears pgpm's bookkeeping for every managed table whose relation no longer exists, returning one row per
table it forgot. [`untransmute`](#untransmute) is the sanctioned way to stop managing a table and deletes
these rows itself; a plain `DROP TABLE` does not, because `config.parent_table` is a `regclass` and carries
no dependency. The row then survives pointing at a dead oid, nothing else ever cleans it up, and every
maintenance tick logs `skip_obtain` / `skip_write_block` / `skip_retain` against it forever. A second, quieter
reason not to leave it: `pg_class` oids are recycled, so a stale row is a standing chance of pgpm one day
believing it manages an unrelated table that lands on that oid.

**It takes no argument on purpose.** The relation is gone, so there is no name to pass, and an oid
parameter would be a foot-gun. With no argument the function can only ever match rows whose relation is
*already* absent, so by construction it cannot touch a live managed table -- safe to expose, safe to re-run
(a no-op when nothing is missing).

**It drops nothing.** A *detached* partition survives its parent's `DROP` still holding its rows, and
"detached, not yet dropped" is exactly the state a referenced partition's retirement sits in between the
cron detach and the completing drop. Any such table is reported by name in `orphan_tables` and
left in place -- destroying data as a side effect of a cleanup command would be the worst possible reading
of "forget". Deal with those by hand. `pgpm.log` is also left intact, as the append-only audit trail it is;
the clearance itself is logged `forget_missing`, naming any orphans in `method`.

`orphan_tables` is **schema-qualified**, and deliberately so: `pgpm.part` records no namespace and the
dropped parent's oid can no longer supply one, so the match is on the child's name alone and could in
principle name a same-named table in an unrelated schema. Read the schema before acting on the list.

Find candidates with `status().parent_missing`; see the runbook's
[a managed table was dropped without untransmute](runbook.md#a-managed-table-was-dropped-without-untransmute).

### `resume` / `pause`

```sql
pgpm.resume(p_parent regclass) returns void
pgpm.pause(p_parent regclass)  returns void
```

Flip `config.paused`. `transmute` registers a table paused; `resume` lets scheduled maintenance begin
obtaining, archiving, retaining (and regraining, if enabled). `pause` stops it.

### `set_regrain`

```sql
pgpm.set_regrain(p_parent regclass, p_target_step text default null) returns void
```

Turn auto-regrain on or off. A non-null `p_target_step` (an interval as text for time/uuidv7, a `bigint`
step as text for id) lets each `maintain` tick feather the oldest frozen coarse child one microbatch
toward that granularity; `null` turns it off (regrain stays operator-driven). Enabling it is always safe:
`regrain_step` enforces its own preconditions, so an un-meetable tick simply retries.

## Observability

### `status`

```sql
pgpm.status() returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text, fks_suspended bigint, fks_unvalidated bigint,
  history_unregrained boolean, retain_drop_failures bigint, retain_backlog bigint,
  retain_detaching bigint, parent_missing boolean
)
```

One row per managed table. Beyond the static config it surfaces:

- `n_partitions` / `coarse_partitions` -- attached partitions, and how many of those are still coarse
  (wider than one step). `coarse_partitions > 0` (and `history_unregrained = true`) is the regraining
  backlog: pruning and fine retention are suspended over that span until it is regrained.
- `inflight_partitions` -- regrain copy-children created but not yet attached. Because regrain copies
  rather than moves, the source stays attached throughout, so a read of the parent is never short and
  these are purely informational.
- `newest_bound` -- the top of the forward grid. This is the write-ahead ceiling: an insert past it is
  refused, since there is no `DEFAULT` to catch it.
- `fks_suspended` / `fks_unvalidated` -- preserve-managed incoming FKs currently dropped (RI off) versus
  re-added `NOT VALID` but blocked from full validation by pre-existing orphans. `fks_suspended` is a
  transient state inside a regrain swap now, so a standing non-zero value means a swap died mid-flight.
- `retain_drop_failures` -- unexpected `DROP` failures since the last successful drop (not a
  child whose chunked archiving simply hasn't caught up yet -- see `retire`). Non-zero means a partition
  is genuinely stuck. Counts `fail_retain_drop`, `fail_retain_crossing` (a live row references an aged
  one and the FK's own `ON DELETE` refused the delete) and `fail_retain_detach` (nowhere to dispatch a
  concurrent detach to), since all three wedge retention the same way.
- `parent_missing` -- the managed relation itself is **gone**: dropped without
  [`untransmute`](#untransmute), leaving the `pgpm.config` row pointing at an oid with no `pg_class`
  entry. Everything else in the row still reports (it comes from pgpm's own catalog), but
  `retain_backlog` is null, because the retention horizon is derived from `max(control)` read from the
  relation and there is no honest answer without it. Clear the state with
  [`forget_missing`](#forget_missing).
- `retain_detaching` -- partitions whose concurrent detach has been dispatched and not yet completed
  Non-zero for a tick or two is normal; persistently non-zero alongside climbing
  `retain_drop_failures` means the dispatch has nowhere to go -- run `pgpm.schedule()`.
- `retain_backlog` -- partitions whose whole range is past the retention horizon but which are not yet
  dropped. Non-zero is normal while `retain_batch` paces a backlog across ticks, or while a write-blocked
  child's chunked archiving is still catching up -- either way it should fall tick over tick. A flat
  `retain_backlog` with climbing `retain_drop_failures` is retention genuinely wedged.

### `check_uuidv7`

```sql
pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
  returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz)
```

Samples a `uuid` column and reports the fraction whose decoded 48-bit timestamp prefix is a plausible
recent time. Genuine UUIDv7/ULID scores `~1.0`; random UUIDv4 scores `~0`. A heuristic, not a proof; this
is the check `transmute` runs to gate the uuidv7 kind.

### `check_time_monotonic`

```sql
pgpm.check_time_monotonic(p_table regclass, p_id name, p_time name, p_sample int default 1000)
  returns table (sampled bigint, monotonic bigint, fraction numeric)
```

Samples rows and reports the fraction of adjacent pairs (ordered by the id) whose time is non-decreasing.
`~1.0` means an id column and a timestamp column co-increase; backfills and out-of-order arrival drive it
down. Use it before retaining an id-partitioned table by a time horizon.

### Observability with pg_flight_recorder (`observe`)

Part of `pgpm_core`: functions that correlate `pgpm.log` against
[`pg_flight_recorder`](https://github.com/dventimisupabase/pg_flight_recorder) (PGFR) telemetry. `pgpm.log`
records exactly when pgpm ran each operation, but pgpm keeps no history of what the rest of the database was
doing; PGFR samples that history continuously but does not know which spikes were pgpm's. These functions
bridge the two over a `pgpm.log` time window. It is **read-only and one-directional** (pgpm never writes into
PGFR, and PGFR needs no changes), and PGFR is **never a dependency**: the PGFR-backed functions raise a
`pgpm`-prefixed error when PGFR is absent.

```sql
pgpm.observe_window(p_parent regclass, p_since interval default '7 days') returns table (
  parent_table regclass, window_start timestamptz, window_end timestamptz, duration interval,
  log_rows bigint, rows_copied bigint, regrains bigint, retains bigint
)
```

The span pgpm was active on a table within `p_since`, plus a summary of what it did. **Pure `pgpm.log`** with
no PGFR dependency, so it works (and is useful) standalone.

```sql
pgpm.impact_report(p_parent regclass, p_since interval default '7 days') returns text
```

"What did the conversion do to the workload?" Derives the window with `observe_window`, then asks
`pgfr_analyze` what the database experienced during it: forced checkpoints, WAL generated, temp spilled, top
wait events, and top queries by execution-time delta. Sections degrade independently (a window with fewer
than two PGFR snapshots, or a `pg_stat_statements` that is absent or was reset, is reported, not fatal).
Requires PGFR.

## Incoming foreign keys

These manage the `preserve` lifecycle: an incoming FK dropped at `transmute` is re-added against the new
parent on a later tick, split into a re-add (`NOT VALID`, enforcing new writes) and a later validation so a
pre-existing orphan can never permanently brick restoration. `maintain` calls `restore` automatically; the
others are operator tools.

### `restore_incoming_fks`

```sql
pgpm.restore_incoming_fks(p_parent regclass) returns int
```

Re-adds each dropped preserve-managed FK against the new parent, returning the number re-added. Self-gates
on quiescence: a no-op while an in-flight, not-yet-attached regrain child remains.

It re-adds each FK `NOT VALID` and **stops there**. `NOT VALID` already enforces every *new* write, so
referential integrity is live the moment this returns; only pre-existing rows are unverified, which
`status().fks_unvalidated` reports. `maintain` finishes the validation on a later tick.

That split is deliberate. `ADD CONSTRAINT` takes `SHARE ROW EXCLUSIVE` on **both** the referencing table
and the managed parent, and `SHARE ROW EXCLUSIVE` conflicts with `ROW EXCLUSIVE`. Validating inline held
that lock across a scan of the referencing table, so writes to the parent blocked for a time proportional
to a table pgpm does not own: 224 ms at 4M referencing rows, and linear.

### `validate_incoming_fks`

```sql
pgpm.validate_incoming_fks(p_parent regclass, p_respect_backoff boolean default false) returns int
```

Finishes validating any preserve-managed FK that was re-added `NOT VALID` but is not yet validated.
Returns the number newly validated; each is isolated, so one still-blocked FK does not stop the others.
In its own transaction the `VALIDATE` holds only `SHARE UPDATE EXCLUSIVE` on the referencing table and
`ROW SHARE` on the parent, neither of which blocks writes.

`maintain` calls this every tick with `p_respect_backoff => true`, which is what completes the validation
without operator action. A *failed* validation re-scans the referencing table to discover it still cannot
succeed, so a failure parks that FK for five minutes (`dropped_fk.validate_retry_after`) rather than
burning that scan every tick. Called by hand it ignores the back-off, since the point of running it
yourself is that you have just cleared the orphans and want the answer now.

### `incoming_fk_orphans`

```sql
pgpm.incoming_fk_orphans(p_parent regclass)
  returns table (referencing_table regclass, constraint_name name, orphan_rows bigint)
```

For each re-added-but-unvalidated FK, the count of orphan rows blocking validation (referencing rows whose
non-null FK columns match no parent key). Handles composite FKs. Use it to find what to clear before
`validate_incoming_fks`.

### `suspend_incoming_fks`

```sql
pgpm.suspend_incoming_fks(p_parent regclass) returns int
```

The inverse of restore: when the closed tail has drain work pending, re-drops any live preserve-managed FK
so the drain never moves a referenced row past a live FK (a live `ON DELETE CASCADE`/`SET NULL` would
otherwise silently mutate the referencing side). A no-op when the closed tail is empty. `maintain` calls
this before each drain step.

## Catalog

All `pgpm` state lives in these tables. Treat them as read-mostly; use the functions above to mutate them.

### `pgpm.config`

One row per managed table (`parent_table` is the primary key). Columns:

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the managed partitioned parent |
| `control_column` | `name` | the partition-key column |
| `control_kind` | `text` | `time`, `id`, or `uuidv7` |
| `partition_step` | `text` | grid width (`1 month` for time/uuidv7; a bigint for id) |
| `partition_anchor` | `text` | grid origin |
| `obtain` | `int` | partitions kept ahead of the frontier |
| `retain` | `text` | retention horizon (interval for time/uuidv7, bigint count for id; null = keep) |
| `retain_batch` | `int` | max partitions one `retain()` call attempts, oldest first (null = unbounded) |
| `regrain_batch` | `int` | rows per regrain COPY microbatch |
| `paused` | `boolean` | maintenance is idle while true |
| `created_at` | `timestamptz` | when transmuted |
| `obtain_retry_after` | `timestamptz` | back-off marker after an obtain lock-race deferral |
| `regrain_max_blocks` | `int` | optional block budget per microbatch (caps wide rows; null = row cap only) |
| `regrain_to` | `text` | auto-regrain target step (null = off; see `set_regrain`) |
| `regrain_cursor` | `text` | how far the in-progress regrain has copied (null = not regraining) |
| `archive_fn` | `regprocedure` | the pluggable archive strategy (null = `none`); see [Archive strategy contract](#archive-strategy-contract) |
| `archive_byte_budget` / `archive_probe_sample` | `bigint` / `int` | byte-budget chunking knobs for the built-in chunked archiver (see [Byte-budget chunked archiving](#byte-budget-chunked-archiving)) |

### `pgpm.part`

The registry of managed partitions. `lo`/`hi` are native-grid values as text.

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the parent |
| `child_name` | `name` | the partition's table name |
| `lo` / `hi` | `text` | native `[lo, hi)` bounds (a partition is coarse when `hi > grid_next(lo)`) |
| `created_at` | `timestamptz` | when created |
| `attached` | `boolean` | false while a regrain is still filling it standalone; true once attached |
| `retiring_at` | `timestamptz` | set when `retire` dispatches a concurrent detach for this partition, so recovery can tell whose detach a pending one was; null for every partition on the ordinary one-step drop path |

Primary key `(parent_table, child_name)`. The non-overlap invariant holds over `attached = true` rows
only; an in-flight child may transiently sit inside a still-attached coarse child.

### `pgpm.log`

An append-only audit trail. `lo`/`hi` are native bounds, `method` a free-text detail, `rows` a count.

**Non-success events are prefixed, never suffixed.** A step that was deferred logs `skip_<mechanism>`
and one that failed logs `fail_<mechanism>`, so no non-success action is ever a prefix-extension of the
success it corresponds to. That makes both ways of querying safe: `action = 'obtain'` and
`action like 'drain%'` match successes only, and `action like 'skip_%'` gives every deferral across all
mechanisms without having to enumerate them. Suffixing (`drain_skip`) would make `drain%` quietly match
the failures too, which is exactly how a guard once reported a starved tick as a successful one.

`action` vocabulary:

| Action | When |
|---|---|
| `transmute` / `untransmute` | conversion and its reversal |
| `obtain` | a forward partition created (`method` = `plain` or `check_skip`) |
| `retain_drop` | a partition dropped by retention (via `retain()` or `retire()`) |
| `retain_detach` / `retain_crossing` / `detach_reap` | a concurrent detach dispatched for a referenced partition / rows deleted to honour a crossing FK's declared `ON DELETE` / an abandoned concurrent detach finalized |
| `regrain_copy` / `regrain_aged` / `regrain_attach` / `regrain` | a regrain microbatch copied rows into a fine child / skipped a below-horizon sub-range (only when `archive_fn` is unset; discarded with the source, never copied) / attached a fine child / completed (`method` = `copy_swap_drop`) |
| `drop_incoming_fk` / `suspend_incoming_fk` / `restore_incoming_fk` / `validate_incoming_fk` | preserve-FK lifecycle events |
| `skip_obtain` / `skip_retain` / `skip_drain` / `skip_regrain` / `skip_archive` / `skip_write_block` / `skip_restore_fk` | a step deferred (lock race or transient error; `method` carries the reason) |
| `fail_restore_incoming_fk` / `fail_validate_incoming_fk` | a preserve-FK re-add failed / a validation was blocked by an orphan |
| `fail_retain_drop` | an unexpected `DROP` failure; the partition was not dropped (`method` carries the error) |

### `pgpm.dropped_fk`

Preserve-managed incoming FKs and their lifecycle.

| Column | Type | Meaning |
|---|---|---|
| `id` | `bigint` | identity |
| `parent_table` | `regclass` | the referenced parent |
| `referencing_table` | `regclass` | the table holding the FK |
| `constraint_name` | `name` | the FK name |
| `definition` | `text` | the captured FK definition (already names the new parent) |
| `restored_at` | `timestamptz` | null = dropped (RI off); set = re-added |
| `validated_at` | `timestamptz` | set = fully validated; null with `restored_at` set = re-added `NOT VALID` (orphans pending) |
| `dropped_at` | `timestamptz` | when the FK was captured and dropped |

### `pgpm.archive_ledger`

One row per archived chunk. See [Byte-budget chunked archiving](#byte-budget-chunked-archiving).

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the managed partitioned parent (primary key with `lo`) |
| `lo` | `text` | native-grid start of this chunk |
| `hi` | `text` | native-grid end of this chunk |
| `child_name` | `name` | the child this chunk belongs to |
| `s3_key` | `text` | set by a real transport strategy; null for a strategy with nothing object-store-shaped to name |
| `etag` | `text` | set by a real transport strategy; null for a strategy with nothing object-store-shaped to name |
| `rows_archived` | `bigint` | rows this chunk archived; null if the strategy reported no progress |
| `archived_at` | `timestamptz` | when this chunk was recorded |

## Partition naming

A fine (one-step) partition is named `<rel>_p<lo>`; a coarse or monolith partition (wider than one step)
is `<rel>_p<lo>_to_<hi>`, both bounds formatted at the step's granularity:

- time/uuidv7: `events_p2026_03` (a fine month), `events_p2026_03_to_2026_07` (the monolith)
- id: `events_p0000000000000010000`, `events_p0000000000000000000_to_0000000000000060000`

The name is a human-facing label; `pgpm.part` holds the authoritative bounds. The `_to_` form also keeps
the orphan guard from mistaking a monolith for an interrupted-run orphan (its digit-only suffix regex
excludes `_to_`).

## Internal adapter layer

Functions named `pgpm._*` are private and may change without notice. The kind-specific logic lives in a
small adapter (`_grid_floor`, `_grid_next`, `_encode`, `_decode`, `_frontier_native`, `_part_name`,
`_native_gt`, `_native_type`), which is where a new partition kind would plug in; the rest (`_transmute`,
`_create_partition`, `_uuid_to_ts`/`_ts_to_uuid`,
`_install_write_block`/`_remove_write_block`/`_enforce_write_blocks`/`_is_write_blocked`,
`_run_archive_strategy`/`_archive_noop`,
`_next_archive_chunk`/`_archive_fully_covered`/`_archive_step`) implements the engine. Do not call
them directly.
