# Reference

Every public function and catalog object in `pg_partition_magician`. The schema is `pgpm`. This is the
authoritative surface; the [user guide](guide.md) explains the concepts and how the pieces fit, and
[REDESIGN.md](../REDESIGN.md) records the operating model.

The mental model in one breath: `transmute` converts a live table into a native `RANGE`-partitioned one
by renaming the original aside and attaching it, with **zero row movement**, as one bounded **monolith**
child (covering `[grid_floor(min), B)`), under a fresh empty `DEFAULT`. Going forward, `obtain` keeps
real partitions ahead of the write frontier, `retain` drops whole partitions past a policy, the **drain**
(the magician's assistant) keeps the `DEFAULT` empty by evacuating strays, and `refine` splits the coarse
monolith into finer partitions on demand. `maintain` is the one procedure `pg_cron` runs.

Conventions used below: `p_parent` is the partitioned parent (a `regclass`); a native grid value is a
`timestamptz` for the `time` and `uuidv7` kinds and a `numeric` for the `id` kind; "the frontier" is
`now()` for `time` and `max(control)` for `id`/`uuidv7`.

## Conversion

### `transmute` (time / uuidv7 grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_drain_adaptive boolean default false, p_force_uuidv7 boolean default false
) returns regclass
```

Converts `p_parent` into a partitioned table online and registers it. The control column's type selects
the kind: a `uuid` column is treated as **uuidv7** (time-ordered; ULIDs stored as `uuid` included), and a
`timestamptz`/`timestamp`/`date` column is **time**. Returns the new partitioned parent (same name as the
original).

The cutover moves no rows: it validates a bound on the live table (one online `SHARE UPDATE EXCLUSIVE`
scan), then in a brief metadata-only step renames the original to a coarse-child name, creates the
partitioned parent, attaches the original as the bounded **monolith** child via the validated `CHECK`
(scan-skipping), and creates a fresh empty `DEFAULT`. The table registers **paused**; nothing happens
until you `resume` it and maintenance runs. An identity column is carried onto the parent and its sequence
advanced to the greater of `max(id) + 1` and the original sequence's own next value, so auto-generated ids
never collide and never re-issue a value the sequence had already moved past (`untransmute` restores it the
same way).

Parameters:

- `p_control` -- the partition-key column. It **must be `NOT NULL`** (a partition key cannot be null;
  `pgpm` never scans to enforce it). A key is not required: if a **primary key or unique constraint**
  includes the control column, `pgpm` reuses it in place and never rewrites it; otherwise the table is
  partitioned **keyless** (no key synthesized). A key that *excludes* the control column is refused (no
  rewrite), as is a *bare* unique index (promote it to a constraint first). Note: `refine` is unavailable
  on a keyless monolith, so its history stays as one coarse child unless a key is added before transmute.
- `p_interval` -- the grid width (`interval '1 day'`, `'1 month'`, `'1 year'`, ...). Cast a bare literal:
  `interval '1 month'` (it disambiguates from the `bigint` overload).
- `p_obtain` -- how many partitions to keep ahead of the frontier.
- `p_retain` -- drop partitions older than this `interval`; `null` keeps everything.
- `p_keep_default` -- keep the `DEFAULT` safety net (the default; leave it on).
- `p_drain_batch` -- rows per drain/refine microbatch.
- `p_anchor` -- the grid origin the boundaries align to.
- `p_paused` -- register paused (the default); `false` goes live immediately.
- `p_incoming_fks` -- `'error'` (refuse if any incoming FK exists), `'drop'` (drop them), or `'preserve'`
  (drop for the conversion and re-add against the new parent once the drain is idle).
- `p_drain_adaptive` -- enable closed-loop feathering for the drain (see `set_drain_adaptive`).
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
select pgpm.transmute('public.events', 'created_at', interval '1 month',
                      p_obtain => 7, p_retain => interval '90 days');
```

### `transmute` (integer / id grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 4, p_retain bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_drain_adaptive boolean default false
) returns regclass
```

The **id** overload, for `int`/`bigint`/`numeric` keys (including Snowflake-style ids). Identical to the
time overload except the grid width is a `bigint` `p_step`, `p_retain` is a `bigint` count of ids, and
`p_anchor` is a `bigint`. There is no `p_force_uuidv7`.

```sql
select pgpm.transmute('public.events', 'id', 10000000, p_obtain => 2);
```

### `untransmute`

```sql
pgpm.untransmute(p_parent regclass) returns regclass
```

Reverses a `transmute`, returning the restored ordinary table. It is a **clean, metadata-only reverse
while the monolith is still intact and holds the whole table**: it detaches the monolith, drops the
childless parent (cascading the empty `DEFAULT` and any empty forward partitions), renames the monolith
back, restores identity and any preserved incoming FKs, and clears `pgpm` state. The monolith is the
attached partition with the smallest `lo`.

It is a **one-way door** once any row lives outside the monolith's range -- a forward partition after the
frontier crosses `B`, a backdated stray in the `DEFAULT`, or finer children from a refinement -- because a
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
- The copy writes a **full second table**, so the migration transiently needs roughly the source's current
  size in extra disk until cutover drops the old hypertable. `from_hypertable_preflight` raises a `NOTICE`
  with the estimate; `from_hypertable_disk_estimate` returns it for sizing a volume ahead of time.
- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, but retention over
  the unrefined **monolith is dormant** until you `refine` it (`retain` only drops attached fine partitions),
  and `refine` is unavailable on a keyless monolith. So a keyless migration that relied on `drop_chunks` will
  not reclaim disk until a key is added and the monolith is refined.

### `from_hypertable`

```sql
pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false
)
```

The one-shot driver: runs `from_hypertable_copy` then `from_hypertable_cutover` back to back. Use it when the
migration does not need to interleave application writes between the phases. `p_interval` and the
`p_obtain`/`p_retain`/`p_keep_default`/`p_drain_batch`/`p_anchor`/`p_paused` parameters pass straight through
to `transmute` (see there); `p_control` is the time column; `p_track_changes` is described under
`from_hypertable_copy`. When `p_retain` is left `null`, the source's `drop_chunks` policy interval (if any) is
carried in.

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
  rows. When `true`, the copy installs an `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values to a `<rel>_pgpm_delta` table, and the cutover reconciles every touched key against the
  live source (delete the copied row, re-insert the current source row). Reconciliation is by the key
  `transmute` reuses (a primary key or unique constraint), so `p_track_changes => true` is **refused on a
  keyless table** (no key to reconcile by). Set it for any workload that updates or deletes rows during the
  migration window.

### `from_hypertable_cutover`

```sql
pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true
)
```

Phase 2: the cutover. First it **pre-builds the destination's primary key and secondary indexes online** (on
the private copy, before any lock -- this is the O(rows) work, deliberately kept out of the blocking window).
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
data-destructive); it has more than one **dimension** (space partitioning); or the `p_control` column does not
exist. On success it raises a `NOTICE` estimating the transient extra disk the migration needs (see
`from_hypertable_disk_estimate`) and a rough copy-time ETA (see `from_hypertable_time_estimate`). Both
`from_hypertable_copy` and `from_hypertable` call it first.

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

The migration time is dominated by two O(rows) but **online** (non-blocking) phases, the per-chunk copy and
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
`config.obtain` of them ready. Returns how many it created. With the `DEFAULT` empty (the normal state)
it uses a plain, scan-free attach. It skips any candidate range that overlaps an existing attached
partition (for example the monolith, which covers the current interval) or that the `DEFAULT` still holds
rows for.

### `drain_step`

```sql
pgpm.drain_step(p_parent regclass, p_batch int default null, p_include_open boolean default false)
  returns text
```

One microbatch of the **assistant drain**: it takes the oldest closed interval still sitting in the
`DEFAULT` (a stray) and moves up to `p_batch` rows (default `config.drain_batch`, capped by
`drain_max_blocks`) into a proper child, attaching the child once the interval is fully moved. An interval
entirely below the retention horizon is reclaimed by a direct `DELETE` instead of materialized. Returns a
status: `idle`, `moved:N`, `attached:<name>:<plain|check_skip>`, or `reclaimed:N[:done]`. `p_include_open`
also drains the current (open) interval.

### `drain_all`

```sql
pgpm.drain_all(p_parent regclass, p_batch int default null, p_include_open boolean default false)
  returns int
```

Loops `drain_step` to `idle` in one call (synchronous; ignores `paused`), returning the number of
microbatches. Suspends any live preserve-managed FK first.

### `retain`

```sql
pgpm.retain(p_parent regclass) returns int
```

Drops every partition whose whole range is older than the retention horizon (`config.retain`), returning
the count dropped. A coarse partition that merely straddles the horizon is **not** dropped, so retention
is suspended over un-refined coarse history until `refine` splits it (or `refine` reclaims the aged
sub-ranges directly). `null` retention drops nothing.

### `refine`

```sql
pgpm.refine(p_parent regclass, p_child name, p_target_step text default null) returns int
```

Splits one **frozen** coarse child `p_child` into finer children of width `p_target_step` (default
`config.partition_step`), returning the number of fine children created. It moves rows into standalone
children in budget-sized microbatches and swaps them in for the coarse child, then drops the now-empty
source; the kept children are insert-only, so the product has no bloat. The whole call runs in one
transaction, so it is **atomic and gap-free**. Retention-aware: a sub-range entirely below the horizon is
reclaimed, never materialized. Refuses (as an exception) when the child is not frozen, the target step
does not subdivide it, or the `DEFAULT` holds rows in its range.

```sql
-- split the monolith into the configured fine granularity, once the frontier has passed it
select pgpm.refine_history('public.events');
```

### `refine_step`

```sql
pgpm.refine_step(p_parent regclass, p_child name, p_target_step text default null, p_batch int default null)
  returns text
```

One resumable microbatch of `refine`: it **copies** (never deletes) a within-horizon sub-range's next
budget-sized batch into its fine child, skips a below-horizon sub-range (discarded with the source at the
swap), and performs the atomic swap once the cursor (`config.refine_cursor`) reaches the coarse `hi`. The
source stays whole and **attached** until that swap, so a read of the parent is never short. Returns
`copied:N`, `swapped:K` (refine complete, K children attached), or a soft no-progress status: `active`
(not frozen yet), `default_dirty` (a stray sits in the range), or `nosubdiv` (the step does not subdivide).
This is the unit `maintain` paces across ticks; because it copies, the cross-tick path opens **no**
read gap (unlike the drain). Its one FK touch is the swap's `DETACH`, which transiently drops and re-adds
any incoming FK within that single transaction.

### `refine_history`

```sql
pgpm.refine_history(p_parent regclass, p_target_step text default null) returns int
```

Convenience: `refine` the oldest coarse child (the monolith -- the smallest-`lo` attached partition) to
`p_target_step`. The hierarchical monolith to coarse to fine path is just repeated `refine` calls with
chosen steps.

### `maintain`

```sql
pgpm.maintain(p_parent regclass) returns text
```

The per-table tick: `obtain`, `retain`, one drain step, restore any preserved FK whose tail has drained,
and -- when auto-refine is on (`config.refine_to`) -- one `refine_step` on the oldest frozen coarse child.
A no-op while paused. Every step is isolated in its own subtransaction under a short `lock_timeout`, so it
never blocks or deadlocks the live workload; a step that loses a lock race is deferred and retried next
tick. Returns a one-line summary, for example
`obtained=2 dropped=0 drain=idle suspended_fk=0 restored_fk=0 refine=copied:5000`.

### `maintain_all`

```sql
call pgpm.maintain_all()
```

A procedure that calls `maintain` for every managed table. This is what the scheduled job runs.

## Scheduling

### `schedule`

```sql
pgpm.schedule(p_every text default '* * * * *') returns bigint
```

Creates (or replaces) the single `pg_cron` job named `pgpm` that runs `call pgpm.maintain_all()` on the
`p_every` cron schedule in the current database, returning the job id. One job covers every managed table
and is idle while they are paused. Raises if `pg_cron` is not installed.

### `unschedule`

```sql
pgpm.unschedule() returns int
```

Removes the `pgpm` cron job (returns the number removed; `0` if `pg_cron` is absent or nothing was
scheduled).

## Control

### `resume` / `pause`

```sql
pgpm.resume(p_parent regclass) returns void
pgpm.pause(p_parent regclass)  returns void
```

Flip `config.paused`. `transmute` registers a table paused; `resume` lets scheduled maintenance begin
obtaining, draining, retaining (and refining, if enabled). `pause` stops it. `drain_all`/`drain_step`
ignore the flag, so you can still drive the drain by hand while paused.

### `set_drain_adaptive`

```sql
pgpm.set_drain_adaptive(p_parent regclass, p_enabled boolean default true) returns void
```

Toggle adaptive (closed-loop) drain feathering. When on, each tick rides the drain's per-tick row budget
just under the WAL supply via AIMD (additive-increase when calm, halve on checkpoint pressure) instead of
the fixed `drain_batch`. Resets the controller state so a toggle starts cleanly.

### `set_drain_ambient`

```sql
pgpm.set_drain_ambient(p_parent regclass, p_factor numeric default 2.0,
                       p_alpha numeric default 0.2, p_floor int default 2) returns void
```

Turn on the self-calibrating ambient-contention backoff (a second feathering signal that yields when the
drain is crowding the live workload, sensed from lock waits and read-I/O latency). `p_factor` is the
relative surge multiple over a learned EWMA baseline (`p_factor => 0` turns it off), `p_alpha` the
baseline smoothing, `p_floor` the idle-box guard.

### `set_refine`

```sql
pgpm.set_refine(p_parent regclass, p_target_step text default null) returns void
```

Turn auto-refine on or off. A non-null `p_target_step` (an interval as text for time/uuidv7, a `bigint`
step as text for id) lets each `maintain` tick feather the oldest frozen coarse child one microbatch
toward that granularity; `null` turns it off (refine stays operator-driven). Enabling it is always safe:
`refine_step` enforces its own preconditions, so an un-meetable tick simply retries.

## Observability

### `status`

```sql
pgpm.status() returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  default_rows bigint, closed_rows bigint, default_oldest text, newest_bound text,
  last_drained timestamptz, drain_skips bigint, fks_suspended bigint, fks_unvalidated bigint,
  history_unrefined boolean
)
```

One row per managed table. Beyond the static config it surfaces:

- `n_partitions` / `coarse_partitions` -- attached partitions, and how many of those are still coarse
  (wider than one step). `coarse_partitions > 0` (and `history_unrefined = true`) is the refinement
  backlog: pruning and fine retention are suspended over that span until it is refined.
- `inflight_partitions` -- children created but not yet attached (a drain or refine in progress; their
  rows are durable but not visible through the parent until attach -- use `snapshot()` for a complete
  read).
- `default_rows` / `closed_rows` -- total and drainable-now rows in the `DEFAULT` (normally near zero;
  these are strays the assistant drain evacuates). `default_oldest` / `newest_bound` bracket the data.
- `last_drained` / `drain_skips` -- progress and stall signals: a non-zero `closed_rows` with a stale
  `last_drained` and a climbing `drain_skips` is a wedged drain; falling `closed_rows` with
  `drain_skips ~ 0` is merely slow.
- `fks_suspended` / `fks_unvalidated` -- preserve-managed incoming FKs currently dropped (RI off) versus
  re-added `NOT VALID` but blocked from full validation by pre-existing orphans.

### `snapshot`

```sql
pgpm.snapshot(p_rowtype anyelement) returns setof anyelement
```

A complete, consistent read during a paced **drain**. While the drain has rows mid-move they live in an
unattached child, so a plain `select` from the parent **undercounts**; `snapshot` unions the parent with
every in-flight drain child. (It deliberately skips a refine's copy-children -- their rows are still in the
attached monolith -- so it never double-counts; refine, which copies, opens no gap to cover.) Pass the
parent's row type as a typed `null` so it can infer the table:

```sql
select count(*) from pgpm.snapshot(null::public.events);
```

It is an optimization fence (it materializes the union, so a `WHERE` does not push down) and does nothing
for writes (a write to an already-moved drain row no-ops until the interval attaches). Single-batch
intervals and the synchronous `drain_all`/`refine()` never open the gap.

### `check_default`

```sql
pgpm.check_default(p_parent regclass)
  returns table (default_rows bigint, closed_rows bigint, oldest text)
```

The `DEFAULT`'s backlog: total rows, rows in closed intervals (drainable now), and the oldest control
value. `status()` surfaces the same numbers.

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

## Incoming foreign keys

These manage the `preserve` lifecycle: an incoming FK dropped at `transmute` is re-added against the new
parent once the drain is idle, split into a re-add (`NOT VALID`, enforcing new writes) and a later
validation so a pre-existing orphan can never permanently brick restoration. `maintain` calls
`suspend`/`restore` automatically; the others are operator tools.

### `restore_incoming_fks`

```sql
pgpm.restore_incoming_fks(p_parent regclass) returns int
```

Re-adds each dropped preserve-managed FK against the new parent, returning the number re-added. Self-gates
on quiescence: a no-op unless the closed tail is drained and no in-flight child remains. Each FK is re-added
`NOT VALID` then validated in a separate subtransaction, so an orphan blocking one validation leaves that
FK enforcing new writes (surfaced as `fks_unvalidated`) without rolling back the re-add or blocking others.

### `validate_incoming_fks`

```sql
pgpm.validate_incoming_fks(p_parent regclass) returns int
```

Finishes validating any preserve-managed FK that was re-added `NOT VALID` but is not yet validated (its
orphans blocked it). Run after clearing the orphans. Returns the number newly validated; each is isolated,
so one still-blocked FK does not stop the others. (Maintenance does not auto-retry validation, since it
would re-scan the referencing table every tick.)

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

All `pgpm` state lives in four tables. Treat them as read-mostly; use the functions above to mutate them.

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
| `keep_default` | `boolean` | keep the `DEFAULT` safety net |
| `drain_batch` | `int` | rows per drain/refine microbatch |
| `default_table` | `name` | the `DEFAULT` partition's table name |
| `paused` | `boolean` | maintenance is idle while true |
| `created_at` | `timestamptz` | when transmuted |
| `obtain_retry_after` | `timestamptz` | back-off marker after an obtain lock-race deferral |
| `drain_max_blocks` | `int` | optional block budget per microbatch (caps wide rows; null = row cap only) |
| `refine_to` | `text` | auto-refine target step (null = off; see `set_refine`) |
| `drain_adaptive` | `boolean` | adaptive feathering on (mode 2) |
| `drain_budget` | `int` | the adaptive controller's current row budget |
| `drain_ckpt_seen` | `bigint` | last forced-checkpoint counter (reactive backstop) |
| `drain_wal_lsn` / `drain_wal_at` | `pg_lsn` / `timestamptz` | previous WAL position + time (for the WAL-rate signal) |
| `drain_wal_high_water` | `numeric` | fraction of the sustainable WAL rate at which to back off |
| `drain_ambient_max_waiters` | `int` | absolute lock-wait cap (0 = off) |
| `drain_ambient_factor` | `numeric` | self-calibrating ambient surge multiple (0 = off) |
| `drain_ambient_alpha` | `numeric` | ambient baseline EWMA smoothing |
| `drain_ambient_floor` | `int` | minimum effective baseline (idle-box guard) |
| `drain_ambient_baseline` / `drain_ambient_io_baseline` | `numeric` | learned EWMA baselines (lock waits, I/O latency) |
| `drain_io_read_time` / `drain_io_blks_read` | `numeric` / `bigint` | previous cumulative `pg_stat_database` I/O sample |

### `pgpm.part`

The registry of managed partitions (excludes the `DEFAULT`). `lo`/`hi` are native-grid values as text.

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the parent |
| `child_name` | `name` | the partition's table name |
| `lo` / `hi` | `text` | native `[lo, hi)` bounds (a partition is coarse when `hi > grid_next(lo)`) |
| `created_at` | `timestamptz` | when created |
| `attached` | `boolean` | false while a drain/refine is still filling it standalone; true once attached |

Primary key `(parent_table, child_name)`. The non-overlap invariant holds over `attached = true` rows
only; an in-flight child may transiently sit inside a still-attached coarse child.

### `pgpm.log`

An append-only audit trail. `lo`/`hi` are native bounds, `method` a free-text detail, `rows` a count.

`action` vocabulary:

| Action | When |
|---|---|
| `transmute` / `untransmute` | conversion and its reversal |
| `obtain` | a forward partition created (`method` = `plain` or `check_skip`) |
| `drain_move` / `drain_attach` | a drain microbatch moved rows / attached a completed interval |
| `retain_drop` / `retain_reclaim` | a partition dropped by retention / aged rows deleted from the `DEFAULT` |
| `refine_copy` / `refine_aged` / `refine_attach` / `refine` | a refine microbatch copied rows into a fine child / skipped a below-horizon sub-range (discarded with the source, never copied) / attached a fine child / completed (`method` = `copy_swap_drop`) |
| `drain_budget` | an adaptive controller step (`rows` = the new budget, `method` = the reason) |
| `drop_incoming_fk` / `suspend_incoming_fk` / `restore_incoming_fk` / `validate_incoming_fk` | preserve-FK lifecycle events |
| `obtain_skip` / `retain_skip` / `drain_skip` / `refine_skip` / `restore_fk_skip` | a step deferred (lock race or transient error; `method` carries the reason) |
| `restore_incoming_fk_failed` / `validate_incoming_fk_blocked` | a preserve-FK re-add failed / a validation was blocked by an orphan |

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
`_create_partition`, the `_feather_*`/`_ambient_*`/`_aimd_next` controller, `_uuid_to_ts`/`_ts_to_uuid`)
implements the engine. Do not call them directly.
