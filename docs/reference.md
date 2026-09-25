# Reference

Every public function and catalog object in `pg_partition_magician`, described **as built**. The schema
is `pgpm`. This is the authoritative surface; the [user guide](guide.md) explains the concepts and how the
pieces fit.

The mental model in one breath: `transmute` converts a live table into a native `RANGE`-partitioned one
by renaming the original aside and attaching it, with **zero row movement**, as one bounded **monolith**
child (covering `[grid_floor(min), B)`), and laying down a **forward grid** of real, bounded partitions
above it. There is no `DEFAULT`: a write no partition covers is refused. Going forward, `obtain` keeps the
grid ahead of the write frontier, `retain` drops whole partitions past a policy, and `regrain` splits the
coarse monolith into finer partitions on demand. `pg_cron` runs two procedures: `maintain_obtain` (just
`obtain`, on its own cadence) and `maintain` (everything else).

Conventions used below: `p_parent` is the partitioned parent (a `regclass`); a native grid value is a
`timestamptz` for the `time`, `uuidv7` and `text_time` kinds and a `numeric` for the `id` kind; "the
frontier" is `now()` for `time`, `max(control)` for `id`, and `greatest(max(control), now())` for
`uuidv7`/`text_time` (both are time grids fed by data, so neither falls behind the clock).

## Conversion

### `transmute` (time / uuidv7 / text_time grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false,
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00',
  p_force_frontier boolean default false
)
```

A **`PROCEDURE`**: invoke it with `CALL`, not `SELECT`, and it returns nothing. The new parent keeps the
original's name, so `p_parent` still resolves to it afterwards.

It `COMMIT`s between its phases, so like [`from_hypertable`](#from_hypertable) it must be called at the
**top level**: a plain `CALL`, never inside a surrounding transaction or an atomic block. A schema-migration
tool that wraps each migration in a transaction (Prisma, Flyway, Liquibase, Rails, Alembic) will therefore
fail it with `invalid transaction termination`. Convert as an operator-driven step instead.

Converts `p_parent` into a partitioned table and registers it. The control column's type selects
the kind: a `uuid` column is treated as **uuidv7** (time-ordered; ULIDs stored as `uuid` included), a
`text`/`varchar` column is treated as **text_time** (a general opaque-sortable-TEXT id -- classic `cuid`
is the motivating case -- decoded via a declared `<prefix><fixed-width base-N encoded epoch>` shape; see
`p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit` below), and a `timestamptz`/`timestamp`/`date` column
is **time**.

The grid is computed in the **zone of the session that runs the call**, recorded in
`pgpm.config.partition_tz` and used for every boundary and partition name from then on, whatever zone
maintenance's session runs in. Month and year boundaries fall at midnight on the 1st in that zone; a
`timestamp` or `date` control column is read as wall time in it. For UTC-aligned boundaries, run
`set timezone = 'UTC'` first. The call refuses a session zone that is not a name in `pg_timezone_names`
(a POSIX rule or a bare abbreviation), and the zone can be changed afterwards only with
[`set_partition_tz`](#set_partition_tz).

The cutover moves no rows, and runs in **three transactions** so that none of its locks scales with the
row count: add the monolith's bound `CHECK` as `NOT VALID` (catalog only, instant); commit, which drops
that statement's `ACCESS EXCLUSIVE`; `VALIDATE` it, the one `O(rows)` read, under `SHARE UPDATE EXCLUSIVE`,
which blocks neither reads nor writes; commit; then one metadata-only transaction renames the original to
a coarse-child name, creates the partitioned parent, attaches the original as the bounded **monolith**
child via the now-validated `CHECK` (scan-skipping), and builds the forward grid. The table registers
**paused**; nothing happens until you `resume` it and maintenance runs.

The trade for the split is that the bound `CHECK` is live for the whole conversion rather than for one
locked statement, so a write outside `[lo, hi)` is rejected for that span (`p_bound_headroom` buys room at
the top), and a conversion that dies between transactions leaves the `CHECK` behind. See
[`transmute_abort`](#transmute_abort).

The new parent also takes over everything `CREATE TABLE ... LIKE` does not carry: the **owner**, table and
**column-level grants**, **row level security** (both `ENABLE` and `FORCE`), every **policy**, table and
column **comments**, and **row triggers**, each in the enabled state it had (`DISABLE`, `ENABLE ALWAYS`
and `ENABLE REPLICA` are kept, on the parent and on the clone every partition receives). All of it is
captured before the rename and re-applied inside
the same transaction as the cutover, so the parent is never reachable without its policies. Partitions
minted later, by `obtain` or a regrain, are given the parent's owner too rather than being
owned by whichever role runs maintenance.

Policies live on the parent, and only on the parent: a parent policy governs parent-routed reads into a
partition, and reaching a partition directly needs grants that live on the parent anyway.

One shape is refused rather than carried: a `FOR EACH ROW` trigger with a transition table
(`REFERENCING OLD/NEW TABLE`), which PostgreSQL does not permit on a partitioned table. Rewrite it as a
statement trigger, which can carry a transition table, or drop it. **Outgoing** foreign keys (this table
referencing another) are carried onto the new parent automatically, so they keep enforcing across every
partition; a `NOT VALID` one is refused rather than carried, because re-adding it at the parent could not
then be metadata-only. **Incoming** keys are governed by `p_incoming_fks` below. An identity column is
carried onto the parent and its sequence
advanced to the greater of `max(id) + 1` and the original sequence's own next value, so auto-generated ids
never collide and never re-issue a value the sequence had already moved past (`untransmute` restores it the
same way).

Parameters:

- `p_control` -- the partition-key column. It **must be `NOT NULL`** (a partition key cannot be null;
  `pgpm` never scans to enforce it). A key is not required: if the **primary key** includes the control
  column, `pgpm` reuses it in place and never rewrites it; if there is no primary key and a **unique
  constraint** includes the control column, that is reused instead; if there is neither, the table is
  partitioned **keyless** (no key synthesized). A **primary key that *excludes* the control column is
  refused** (no rewrite), whatever other unique constraints the table has: it could not be carried onto
  the parent, and `pgpm` will not adopt a different key and leave it behind on the monolith, where it
  would enforce nothing for new rows. The error names the constraint and the control column. A *bare*
  unique index is refused too (promote it to a constraint first). Column **order** within the key
  is free: PostgreSQL requires only that the key *contain* the partition key, and `pgpm` reads the key for
  identity, never for ordering. Choose it for your own reads (see
  [the guide](guide.md#the-cutover-moves-no-rows)). Note: `regrain` is unavailable
  on a keyless monolith, so its history stays as one coarse child unless a key is added before transmute.
- `p_interval` -- the grid width (`interval '1 day'`, `'1 month'`, `'1 year'`, ...). Cast a bare literal:
  `interval '1 month'` (it disambiguates from the `bigint` overload).
- `p_obtain` -- how many partitions to keep ahead of the frontier.
- `p_retain` -- drop partitions older than this `interval`; `null` keeps everything. Must not be
  negative: a negative interval is refused before anything is committed, because it would put the
  retention horizon past the partition taking writes and the first maintenance tick would drop every
  partition. `interval '0'` is allowed and keeps only the partition taking writes.
- `p_regrain_batch` -- rows per regrain COPY microbatch.
- `p_anchor` -- the grid origin the boundaries align to (month and year steps count from its month in
  the session's zone; day and shorter steps count seconds from the instant).
- `p_paused` -- register paused (the default); `false` goes live immediately.
- `p_incoming_fks` -- `'error'` (the default: refuse if any incoming FK exists) or `'preserve'` (drop each
  for the conversion and re-add it against the new parent, which `maintain` does on a later tick, or
  `restore_incoming_fks` does now). `'drop'` is also accepted, but it is **not** a third behavior: it takes
  the same path as `'preserve'`, so the keys are recorded and restored just the same. The drop happens in
  the cutover, the last of the conversion's three transactions, in the same transaction that records the
  key, so a conversion that fails or is abandoned before then leaves every incoming FK exactly where it
  was, and one that fails in the cutover rolls the drop back with it. Referential integrity on the
  referencing table is off only between a completed cutover and the restore.
- `p_force_uuidv7` -- skip the uuidv7 plausibility refusal (see below).
- `p_tt_prefix`, `p_tt_width`, `p_tt_radix`, `p_tt_unit` -- **text_time only**, and all four are required
  together when the control column is `text`/`varchar`. They describe the column's shape: a constant
  literal prefix (`''` if none, `'c'` for classic `cuid`), the fixed character width of the
  encoded-count field (`8`), the base it's encoded in (`36`), and the time unit it counts (`'ms'` or
  `'s'`). See [`check_text_time`](#check_text_time) and the [ready-to-use recipes](guide.md#pick-the-kind)
  for cuid v1, ULID, KSUID and MongoDB ObjectId.
- `p_tt_alphabet` -- **text_time only**, optional. The digit-to-character mapping, one character per
  value `0..p_tt_radix-1`, in order. `null` (the default) uses the contiguous `0123456789abcdefghi...z`
  convention, valid for `p_tt_radix` up to 36; a radix above that, or a different character set
  entirely (ULID's Crockford base32 skips I/L/O/U; KSUID's base62 is digits then uppercase then
  lowercase), requires spelling the alphabet out explicitly. Its length must equal `p_tt_radix`.
  A mixed-case alphabet (KSUID's) needs the control column on a bytewise collation (`collate "C"`):
  RANGE bounds on a `text` column compare under the column's collation, and `en_US` sorts `a` before `P`
  where base62 puts it after. `transmute` refuses otherwise, naming the collation and the first
  misordered digit pair; see [`check_text_time`](#check_text_time) and the
  [guide](guide.md#pick-the-kind).
- `p_tt_discard_bits` -- **text_time only**, default `0`. After decoding the whole
  `p_tt_prefix`-plus-`p_tt_width`-characters field as one number, discard this many of its low-order
  bits before treating what remains as the time count. `0` (the default) means the decoded field *is*
  the count already (cuid, ULID); KSUID needs `128`, since it base-`62`-encodes its entire 160-bit
  payload (32-bit timestamp + 128 bits of random) as a single number, not the timestamp alone.
- `p_tt_epoch` -- **text_time only**, default `'1970-01-01 00:00:00+00'` (standard Unix epoch). The
  zero-point the decoded count is measured from. Only formats with a non-standard epoch (KSUID:
  `'2014-05-13 16:53:20+00'`) need to set this.
- `p_force_text_time` -- skip the text_time plausibility refusal (see below).
- `p_bound_headroom` -- push the monolith's upper bound `hi` this many grid steps further out. The bound
  `CHECK` refuses writes at or past `hi` for the whole conversion, so raise this if the frontier could
  cross `hi` while the validation scan runs. `0` (the default) puts `hi` at the first grid boundary above
  the frontier. **This `hi` is not scoped to the conversion: it becomes the monolith's permanent, attached
  partition bound at cutover.** There is no way to widen the write ceiling for the conversion without
  also widening the monolith's permanent range by the same amount. The monolith cannot be regrained until
  the frontier has passed that same `hi` (see [`regrain_step`](#regrain_step)), so headroom sized to
  cover a write-ceiling window lasting seconds to minutes also delays regrain eligibility for the
  *entire* monolith by the same number of grid steps -- a full extra week on a weekly grid, for
  `p_bound_headroom => 1` -- even though almost all of its rows are, by the time the frontier reaches
  that point, unambiguously historical. Weigh that against the write-ceiling risk headroom is actually
  buying; raising it is not free.
- `p_lock_timeout` -- how long each phase waits for a lock before giving up (`'5s'` by default; any
  `lock_timeout` value). This bounds a wait, it does not shorten one: the locks themselves are brief. It
  matters because a *pending* `ACCESS EXCLUSIVE` request blocks every lock request queued behind it, so
  without a bound one long-running query stalls the whole table for as long as it runs. A bad value is
  refused before anything is committed. On timeout, a failure in phase 1 leaves the table untouched, and
  one in the cutover leaves the recorded, resumable state [`transmute_abort`](#transmute_abort) and
  `maintain_all`'s sweep handle; either way, re-run `transmute` to retry.
- `p_force_frontier` -- **uuidv7 and text_time only.** For these kinds the frontier is the newer of the
  column's maximum and `now()`, so one row minted by a client with a wrong clock sets the frontier, and with
  it the monolith's permanent `hi`, as far ahead as that clock was wrong: every row written until then lands
  in the monolith, `status()` shows nothing abnormal, and the monolith cannot be regrained nor anything
  behind it dropped until the clock really passes `hi`. The plausibility sampling cannot see it (one bad row
  in 402 is fraction 0.9975). So `transmute` refuses, before anything is committed, when the column's newest
  value decodes to more than **one partition step plus one hour** past `now()`, naming that value, its
  decoded timestamp, the `hi` it would have imposed and the `hi` the clock alone would give. The allowance
  is measured from `now()`, never from a `p_bound_headroom`-widened bound: headroom is you asking for a
  farther `hi`, and it does not also widen what the data may impose. A few minutes of ordinary clock skew is
  always inside the allowance. The remedy is to delete or correct those rows (the message names the value
  every offending row sorts above) and re-run; `p_force_frontier => true` accepts the far `hi` knowingly,
  with a `NOTICE` restating what it costs. See [`check_uuidv7`](#check_uuidv7) and
  [`check_text_time`](#check_text_time), whose `newest_decoded`/`newest_in_future` show the maximum before
  you convert.

Refuses up front (leaving the table untouched) when: a key (primary key or unique constraint) exists but
excludes `p_control`, or only a *bare* unique index includes it (promote it to a constraint first); the
control column is `float`/`double` (imprecise boundaries); a `time`-kind control column
is not a timestamp/date, a `uuidv7` control is not `uuid`, or a `text_time` control is not `text`/`varchar`;
a `uuid` control samples as overwhelmingly random (UUIDv4) and `p_force_uuidv7` is not set; a `text_time`
control is missing any of `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit`, has a `p_tt_radix` outside
2-36 with no `p_tt_alphabet` supplied, a `p_tt_alphabet` whose length does not match `p_tt_radix` or that
repeats a character, a non-positive `p_tt_width`, a negative `p_tt_discard_bits`, an alphabet the control
column's collation does not order the way base-`p_tt_radix` place value does (KSUID's base62 on an
`en_US` column; put the column on `collate "C"`, which `p_force_text_time` does not override), or
samples as not matching the declared shape and `p_force_text_time` is not set; a `uuidv7` or `text_time` control's newest
value decodes to more than one partition step plus one hour past `now()` and `p_force_frontier` is not set
(a future-dated row would pin the monolith's permanent `hi` there); a non-PK `UNIQUE` secondary index does not include the
partition key (global uniqueness could not be enforced); an incoming FK exists and `p_incoming_fks` is
`'error'`; a standalone table matching the child-partition naming already exists (an orphan from an
interrupted run); or a relation already occupies one of the `<index>_pgpm` names the conversion needs for
the partitioned copies of the table's secondary indexes (also usually a leftover from an interrupted run).

```sql
call pgpm.transmute('public.search_history', 'id', interval '1 month',
                      p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
```

(that's cuid v1; ULID, KSUID and MongoDB ObjectId need `p_tt_alphabet` and/or `p_tt_discard_bits`/
`p_tt_epoch` too -- see the [ready-to-use recipes](guide.md#pick-the-kind) for all four.)

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
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s'
)
```

The **id** overload, for `int`/`bigint`/`numeric` keys (including Snowflake-style ids). Also a
`PROCEDURE`. Identical to the time overload except the grid width is a `bigint` `p_step`, `p_retain` is a
`bigint` count of ids (not negative, as for the time overload: a negative count is refused up front, and
`0` keeps only the partition taking writes), and `p_anchor` is a `bigint`. There is no `p_force_uuidv7`.

```sql
call pgpm.transmute('public.events', 'id', 10000000, p_obtain => 2);
```

### `transmute_abort`

```sql
pgpm.transmute_abort(p_parent regclass) returns boolean
```

Abandons a conversion that died between transactions, dropping the `pgpm_monolith_bound` `CHECK` it left
on the table and clearing its `pgpm.transmute_inflight` row. Returns `false` if there is no in-flight
conversion to abandon, and raises if one is still running in another session. That is all there is to
undo: incoming foreign keys are dropped only by the cutover, so a conversion that never got there left
them in place, and there is nothing for this to re-add.

It **abandons; it does not resume**. Finishing a half-done conversion of a live table unattended is a
larger action than pgpm will take on your behalf. To try again, call `transmute` again: it finds the
recorded row and reuses the bound already on the table rather than recomputing one against a frontier that
has since moved.

You mostly will not need to call this. Every `maintain_all` tick sweeps for abandoned conversions and
undoes them, and it decides "abandoned" from whether the session that claimed the conversion is still
connected rather than from a timeout, so a long validation scan is never mistaken for a dead one and an
operator whose session is still open keeps the right to retry.

### `untransmute`

```sql
pgpm.untransmute(p_parent regclass) returns regclass
```

Reverses a `transmute`, returning the restored ordinary table. It is a **clean, metadata-only reverse
while the monolith is still intact and holds the whole table**: it detaches the monolith, drops the
childless parent (cascading any empty forward partitions), renames the monolith
back, restores identity, the row triggers (each in the enabled state the parent had) and any preserved
incoming FKs, and clears `pgpm` state. The monolith is the
attached partition with the smallest `lo`.

It is a **one-way door** once any row lives outside the monolith's range -- a forward partition after the
frontier crosses `B`, or finer children from a regraining -- because a
metadata-only reverse would lose those rows.

The door is checked twice. Once before anything is touched, under no lock a writer would feel, so a
refusal never blocks anyone. And again under the **`ACCESS EXCLUSIVE` lock on the parent** that the
detach and drop need, taken explicitly just before them, so a row that commits into a forward partition
while `untransmute` is waiting for that lock is refused rather than dropped with the parent. The wait is
bounded by the caller's `lock_timeout`, and a refusal rolls the whole call back, leaving the table exactly
as it was. `untransmute` must run in a `READ COMMITTED` transaction (the default): a stricter isolation
level cannot give the under-lock check a snapshot taken after the lock, so it refuses up front rather than
proceed on a stale one.

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

- A single time/`RANGE` dimension on a `timestamptz`, `timestamp` or `date` column, migrated on that column:
  `p_control` must be the dimension column, because the copy is bounded on the dimension's chunk ranges and
  on any other column it would silently lose rows. **Continuous aggregates**, **space partitioning** (more
  than one dimension), **integer-time** dimensions and a `p_control` other than the dimension are refused up
  front.
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
to `transmute` (see there); `p_control` is the time dimension column; `p_track_changes` and `p_predrain` are described
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
the workload continue, then run `from_hypertable_cutover` when ready. Each chunk's bounds are applied in the
dimension's own type (`timestamptz`, `timestamp` without time zone, or `date`), so the copy is exact under any
session `TimeZone`; a hypertable on a dimension of any other type is refused here.

- `p_track_changes` -- capture in-flight **updates, deletes and out-of-order appends**, not just in-order
  appends. When `false` (the default), the cutover catches up **append-only**: it takes the rows whose
  control column is at or past the copy watermark (`max(control)` in the destination) and nothing else.
  That is correct only for a workload whose rows arrive in control order and are never changed afterwards.
  It **cannot see updates and deletes** to already-copied rows, and it **cannot see a row that arrives
  during the window with a control value below the watermark**: multi-writer clock skew, batched device
  uploads and backfills all produce such rows, and they are the normal shape of an IoT workload. Neither
  is lost silently: the cutover compares the two sides under its lock and **refuses the swap** on any
  mismatch (see `from_hypertable_cutover`), so the failure mode is a refused cutover naming both counts,
  not a table dropped short. A row landing **exactly at** the watermark is taken on a keyed table (the
  catch-up is inclusive there, with a key anti-join against the destination so the copied row already at
  that value is not duplicated); on a keyless table it is detected by the same check rather than taken.
  That append-only tail is pre-drained online before the lock too
  (`from_hypertable_drain_appends`, run automatically by the cutover).

  **Whenever the table has a primary key or unique constraint, pass `p_track_changes => true`.** The
  append-only path is the unsafe one for a real workload, and tracking costs one row trigger and one small
  delta table for the duration of the window. The default is unchanged for now.

  When `true`, the copy installs an
  `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values (plus a monotonic `pgpm_seq` ordering column) to a `<rel>_pgpm_delta` table. That
  backlog is reconciled **online, in micro-batches, before the cutover** (`from_hypertable_drain_delta`, run
  automatically by the cutover), and the cutover applies only the residual under the lock. Reconciliation is
  by the key `transmute` reuses (a primary key or unique constraint), so `p_track_changes => true` is
  **refused on a keyless table** (no key to reconcile by) and on a key with a **nullable (non-control)
  column** (a `NULL` key component can never be reconciled, so the change would be lost). Set it for any
  workload that updates or deletes rows, or can append out of order, during the migration window.

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
control range for chunk exclusion. The driver **commits per batch** (so WAL recycles); `_step` does one
batch (no commit, returns the keys it cleared). No throwaway index is built or dropped for it: the
per-batch delete uses the key index the cutover later adopts.

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
`from_hypertable_drain_delta`. Assumes the append-only contract (no updates or deletes to copied rows, and
appends arriving in control order), exactly as the under-lock catch-up does. A row that arrives behind the
watermark is invisible to both; the cutover's conservation check refuses the swap rather than lose it. Use
`p_track_changes` for update/delete workloads and for any workload that can append out of order.

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
Then it takes the **`ACCESS EXCLUSIVE` window**: catch up the writes that arrived during
the copy (append-only, or a full delta replay when `from_hypertable_copy` ran with `p_track_changes => true`
-- auto-detected via the delta table, so the two phases cannot disagree), **verify that the source and the
destination hold the same number of rows** (below), drop the hypertable, rename the copy
into place, **adopt** the pre-built unique indexes as the original `PRIMARY KEY`/`UNIQUE` constraints
(`ALTER TABLE ... USING INDEX`, metadata-only) and rename the secondary indexes back to their original names,
re-add the identity columns (which `CREATE TABLE LIKE` does not carry), then hand off to `transmute`. Because
the index builds happen before the lock, the blocking window is the catch-up, one `count(*)` over the source,
and metadata: the count is the only step in it that reads the whole table, and it is a read, not a rebuild.
It also preserves each identity
sequence's exact position: `transmute` seeds past `max(id)`, but if the source sequence was further ahead
(gaps from rollbacks, caching, or deleted high rows) the migrated sequence is advanced to the source's next
value so those ids are not re-issued. The swap is one transaction: it
commits whole or rolls back whole, leaving the source intact on any failure. Requires `from_hypertable_copy`
to have run (the destination must exist). Parameters past `p_interval` pass through to `transmute`.

**The cutover refuses to swap unless the two sides agree.** Before anything is dropped, and still under the
lock (so both numbers are exact), it compares `count(*)` over the source with the destination's row count
after the catch-up. On a mismatch it raises `pg_partition_magician: from_hypertable_cutover(...) refusing to
swap: the source holds N rows but the destination would hold M ...`, naming both counts and the difference,
and the whole cutover rolls back: the source is untouched and still a hypertable, the destination copy is
intact, and nothing was handed to `transmute`. On the append-only path the cause is rows that arrived during
the online window with a control value at or below the copy watermark (out-of-order appends, a backfill, or
an update or delete of a copied row). Those rows are below the watermark, so **re-running the cutover cannot
find them**: re-run `from_hypertable_copy` with `p_track_changes => true` (it drops and rebuilds the
destination), or, on a keyless table, pause writes to the source for the duration of the copy. On the
tracking path a mismatch means a write reached the source without firing the capture trigger
(`session_replication_role = replica`, or the trigger disabled); fix the writer and re-run the copy with
tracking. The source's `count(*)` runs under the lock and is proportional to the table's size; the
destination's count is taken before the lock and adjusted by exactly what the catch-up changed, so it adds
nothing there.

**Do not rename or replace either side of the swap while the cutover is preparing.** The source's name is
resolved once at the start, and the index pre-builds above are deliberately outside the lock, so that is the
longest stretch in which the name can stop meaning what it meant -- and `LOCK TABLE` freezes whatever a name
means *at lock time*. The cutover therefore locks the source **by oid** and then requires the name to still
resolve back to it, and does the same for the destination against the oid its own existence check found,
locking that too. Either mismatch **aborts** the cutover with an error naming both oids: there is no partial
progress to preserve (the swap is one transaction, and the copy and any drained batches survive), and
adapting to the new name would silently migrate a table the operator did not ask for. Re-run the cutover once
the name is settled. A destination substituted *before* the cutover was called is out of reach of this check,
since nothing in the module records what `from_hypertable_copy` built.

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
exist; `p_control` is **not the time dimension** column (the copy is bounded chunk by chunk on the dimension's
ranges, so on any other column it would silently lose rows; the message names the actual dimension); the
dimension is **integer-time** (`smallint`, `integer` or `bigint`: only `timestamptz`, `timestamp` and `date`
dimensions are supported, because an integer dimension's chunk ranges are not in the column the copy reads,
so it would copy nothing); an **outgoing** foreign key is `NOT VALID`; or an **incoming** foreign key
references anything other than the key pgpm will reuse. On success it raises a `NOTICE` estimating the
transient extra disk the migration needs (see `from_hypertable_disk_estimate`) and a rough copy-time ETA (see
`from_hypertable_time_estimate`). Both `from_hypertable_copy` and `from_hypertable` call it first, and
`from_hypertable_cutover` repeats the two dimension checks in its own right, since a destination left by an
earlier copy is enough to reach the cutover's drop without preflight having run.

#### Foreign keys

Both directions are carried across the migration.

An **outgoing** key (the migrated table referencing another table) is replayed verbatim on the private copy
during `from_hypertable_copy` as `NOT VALID`, validated there in its own transaction, and re-added at the new
parent after the handoff. Validating on the copy keeps the `O(rows)` scan off the cutover's lock, and because
the copy becomes the monolith child with an already-validated key, the parent-level add is metadata-only.
Logged `from_hypertable_carry_fk` and `from_hypertable_adopt_fk`.

An **incoming** key (another table referencing the migrated one) is captured and dropped in the cutover,
since the source hypertable cannot be dropped while one points at it, then re-added against the new parent
afterwards through `pgpm.dropped_fk`, so
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
ends at the last instant a 48-bit millisecond prefix can carry, `10889-08-02 05:31:50.65504+00`; a
`text_time` grid ends wherever the declared `p_tt_width` digits at `p_tt_radix` run out (classic cuid's
8 base36 digits reach year 2059).

This is the only thing standing between the workload and a write with nowhere to go, since a row outside
the grid is refused rather than parked. `config.obtain x partition_step` is therefore both the slack if
maintenance stalls and a ceiling on how far ahead an application may write.

### `extend_to`

```sql
pgpm.extend_to(p_parent regclass, p_value text, p_max int default 10000) returns int
```

Builds every missing partition on the existing grid, from the current forward edge up to and including
the one that would hold `p_value`, and returns how many it created. Manual and explicit, like `obtain`:
`maintain` never calls it. It exists because `obtain`'s lookahead (`config.obtain x partition_step`) is a
hard ceiling now that there is no `DEFAULT`, and an `id` grid's frontier is data-driven and can jump past
it -- a sequence restart, a non-dense Snowflake/ULID generator, a bulk import, a backfill -- with no way to
recover, since the write that would advance the frontier past the ceiling is the write that fails.

`p_value` is in the control column's own representation: a bare id for `id`, a `uuid` literal (as text)
for `uuidv7`, the encoded text id for `text_time`, anything `timestamptz` accepts for `time`. Pass
exactly what you would insert.

It never moves the frontier or touches data, only creates empty partitions, and is idempotent: partitions
that already exist (or overlap an attached one, like the monolith) are left alone. `p_max` bounds how many
NEW partitions one call may create, checked with a dry count before any DDL runs, so a wildly-off
`p_value` is refused loudly and immediately -- creating nothing -- rather than silently stopping `p_max`
partitions short of the value actually asked for. Like `obtain`, it stops (here, raises) if the next grid
boundary cannot be expressed (the `uuidv7`/`text_time` ceilings described above).

### `retain`

```sql
pgpm.retain(p_parent regclass) returns int
```

Drops every partition whose whole range is older than the retention horizon (`config.retain`), returning
the count dropped. A coarse partition that merely *straddles* the horizon is **not** dropped, since it
still holds within-horizon data, so its aged span is not reclaimed for as long as it straddles.

A coarse child is **not exempt from retention, only all-or-nothing about it**: once its whole range is
past the horizon it drops like any other partition, in one step. What `regrain` changes is the
*granularity* of that reclamation, not whether it happens -- split into fine children, each drops on its
own schedule, so storage falls gradually rather than in one cliff (and `regrain` reclaims below-horizon
sub-ranges directly rather than materializing partitions only to drop them). `null` retention drops
nothing.

`config.retain_batch` caps how many eligible partitions one call will **attempt** (write-block ensure,
archive-coverage check, drop), oldest first; the rest of the backlog waits for later calls -- on the
scheduled path, later `maintain` ticks, each its own transaction. `null` (the default) is unbounded. The
cap bounds attempts, not successes: an unexpected drop failure at the head of the backlog defers
everything behind it until it clears (the wedge shows as a flat `status().retain_backlog` with climbing
`retain_drop_failures`). A child whose chunked archiving simply hasn't caught up yet is *not* a wedge --
`retain_drop_failures` stays at zero for that; see [`retire`](#retire).

`retain()` is a loop over [`retire`](#retire): it picks the eligible set and `retire` carries the
per-partition protocol. Every eligible partition is write-blocked before it is dropped, and the block
holds for a session running as `session_replication_role = replica` too (see [`retire`](#retire)).

### `retire`

```sql
pgpm.retire(p_parent regclass, p_child name) returns boolean
```

The sanctioned single-partition drop: `retain()`'s per-partition body, public and claim-guarded, for an
external assistant (e.g. an archive-then-drop scanner) -- or several cooperating ones -- to drive
retirement directly. It claims the `pgpm.part` row, ensures the child is write-blocked
(`pgpm._install_write_block`, idempotent), checks `pgpm._archive_fully_covered`, and only then `DROP`s, deletes the catalog row, and logs `retain_drop`. Returns `true`
iff this call dropped the partition.

The write block is a trigger on the child, enabled `ALWAYS`, so it fires regardless of
`session_replication_role`: a logical-replication apply worker, or a loader running as `replica` to
silence triggers, is refused exactly as an ordinary session is. A block an older pgpm installed in the
origin-only state is brought up to `ALWAYS` by the first `maintain` tick after `install.sql` is re-run.

`retire` never widens what retention may drop -- a caller only picks **which** eligible partition and
**when**. It refuses (raises) an unmanaged table, a table with no retention policy (`config.retain` is
null), a partition whose range is not entirely at/below the retention horizon, and an in-flight
(unattached) regrain copy-child.

It returns `false`, without side effects and without logging anything, in three normal, retryable
situations: the `pgpm.part` row is absent (already retired by another actor), it's claimed by a
concurrent transaction (each partition has exactly one owner at a time), or the partition is
write-blocked but not yet `pgpm._archive_fully_covered` -- chunked archiving simply hasn't caught up yet.
Only a genuinely unexpected failure in the `DROP` itself is logged (`fail_retain_drop`) and returns
`false`.

#### Retiring a partition an incoming FK references

If any foreign key references the managed parent, the partition cannot be dropped in one step, whether or
not any row actually references the aged range: `retire` detaches it first, and the detach runs in the
standing `pgpm_detach` cron job rather than in `retire` itself. `retire` **dispatches** it, by rewriting
that job's command, and returns `false`; a later call finds the partition detached and completes the
`DROP`. Retiring a referenced partition therefore takes at least two calls and requires
[`pgpm.schedule`](#schedule) to have been run.

The sequence, per partition:

1. If a live row references a doomed one, `DELETE` exactly those keys from the parent, so PostgreSQL
   applies the referential action the operator declared. `CASCADE`, `SET NULL` and `SET DEFAULT` proceed,
   and a `CASCADE` reaches whatever further tables it would reach on any other delete; `NO ACTION` and
   `RESTRICT` refuse, and the refusal is logged `fail_retain_crossing` with the
   constraint's own error, leaving the partition intact. A successful crossing is logged `retain_crossing`.
2. Set `pgpm.part.retiring_at` and `pgpm.part.retiring_oid`, and point `pgpm_detach` at this partition's
   concurrent detach, in one transaction, logged `retain_detach`. With no such job, `fail_retain_detach`
   is logged instead.
3. On a later call, with the partition detached, return the cron job to idle, `DROP` the partition, delete
   the catalog row and log `retain_drop`.

`fail_retain_crossing`, `fail_retain_detach` and `fail_retain_identity` all count in
`status().retain_drop_failures`; in-flight detaches show in `status().retain_detaching`. A partition that
is detached but carries no `retiring_at` was detached by something other than pgpm, and `retire` refuses to
drop it.

##### What `retire` checks a partition's identity against

The detach reaches pg_cron as text naming the partition, and pg_cron re-resolves that name in a session of
its own, a tick or more later, with no lock held on the partition in between. So if something else takes
the name `schema.child` in that gap, and attaches the new relation to the same parent, the dispatched
detach lands on it. pgpm cannot prevent that. What it does instead is record the partition's OID in
`pgpm.part.retiring_oid` at dispatch, and check it at the top of every later `retire` call, before any
side effect: the name must still resolve, and resolve to that OID. When it does not, `retire` logs
`fail_retain_identity`, returns the standing job to idle, and does nothing else -- no re-dispatch, and in
particular no `DROP`. The detach can still land on a substitute; the destructive half cannot.

`retiring_oid` is set only for a partition being retired through a detach. The ordinary one-step path,
whose bare `DROP TABLE schema.child` has nothing else between it and the write block, is covered by
`pgpm.part.child_oid`, recorded when the partition entered the catalog and so populated for every
partition. `retire` checks both, independently, and a disagreement with **either** refuses; the `method`
column names whichever anchor disagreed, so a stale dispatch and a stale catalog row are distinguishable.

That refusal is permanent, not retryable: no later tick makes the name mean the right object again. On the
detach path it shows up as `retain_detaching` stuck non-zero with `retain_drop_failures` climbing; on the
one-step path as `retain_backlog` flat with the same count climbing. Recovery is an operator decision --
put the intended relation back under that name, or delete the `pgpm.part` row if it is gone for good. A
null anchor is not consulted at all: `retiring_oid` is null for every partition on the one-step path and
for a retirement already in flight when the column was added, and `child_oid` is null for a row whose name
no longer resolved when the backfill ran. Both read as unanchored and behave as they did before.

### `_detach_reap`

```sql
pgpm._detach_reap() returns int
```

Finishes any concurrent detach whose session died part-way, and returns how many it finished.
`maintain_all` calls it before the per-parent loop, alongside `_transmute_reap`, because it is the most
urgent thing in a tick: a backend killed during a concurrent detach's *wait* phase leaves the partition
half-detached, with its rows **already invisible through the parent**, so rows appear to vanish from the
table while the partition is neither detached nor dropped. `ALTER TABLE ...
DETACH PARTITION ... FINALIZE` completes it, logged `detach_reap`.

It finalizes only an **abandoned** detach, never a live one. A concurrent detach spends its whole wait
phase looking exactly like an abandoned one in the catalog (the partition flagged pending detach, its rows
already invisible), for as long as the longest transaction holding a lock on the parent, and `maintain_all`
runs on the same cadence as the `pgpm_detach` job, so it routinely meets one in that state. A pending
partition is left alone while any other session is still running its detach: one holding or waiting for a
lock on the partition itself, one parked waiting for a transaction that has the parent locked, or one whose
current statement is a `DETACH PARTITION ... CONCURRENTLY` naming the partition. The first two are read
from `pg_locks`, which every role can see, so a detach run by hand under another role is covered as well.
Nothing is logged for a skipped partition: a detach in progress is the expected state, not a deferral, and
`status().retain_detaching` already counts pgpm's own. The residual failure is deferring a reap by one
tick, never finalizing a detach that is still running.

It drops nothing: `retire` completes pgpm's own retirements on the normal path, and an operator's hand-run
detach that was interrupted is finished and then left alone.

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

Only one regrain runs per parent at a time: a second one is refused with an error naming the one in
flight. Let it finish, or stop it with [`regrain_cancel`](#regrain_cancel), then re-run.

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
source stays whole and **attached** until that swap, so a read of the parent is never short.

The skip is decided once, as the cursor passes the sub-range, and the swap **re-checks it** against the
retention policy in force at that moment. If a skipped sub-range is no longer entirely below the horizon
(`set_retain` loosened retention, to a longer value or `null`, after the skip), the swap **refuses** with an
error naming the range, because dropping the source would destroy rows the table is now configured to
keep. The refusal locks and changes nothing: the source stays attached, the cursor stays at `hi`, and the
run resumes from there. Set `retain` back and the next tick swaps, or [`regrain_cancel`](#regrain_cancel)
and re-run under the new policy. Through `maintain` the refusal appears as a `skip_regrain` row carrying
the message. A sub-range that already has a fine child is never skipped, even once it ages: its copy is
finished instead, so an attached partition always holds its whole range.

Returns `prepared` (the first tick, which installs change capture and copies nothing), `reconciled:N`,
`copied:N`, `reconciling:N` (the swap is waiting for the captured backlog to clear), `swapped:K` (regrain
complete, K children attached), or a soft no-progress status: `active` (not frozen yet) or `nosubdiv`
(the step does not subdivide). This is the unit `maintain` paces across ticks; because it copies, the
cross-tick path opens **no** read gap. Its incoming-FK touch is the swap's `DETACH`, which transiently
drops and re-adds any incoming FK within that single transaction. Outgoing FKs are carried onto each fine
child while it is still empty, so the swap never validates one under its lock.

Committed DML against the source while a regrain is in flight is honoured. A trigger on the source records
changed keys into a per-parent delta table, and a reconcile pass treats the **source** as the authority for
each captured key, so a row inserted, deleted or updated mid-regrain is not lost, resurrected or reverted
by the swap. The trigger is enabled `ALWAYS`, so DML applied with `session_replication_role = replica` (a
logical-replication subscriber's apply worker, a loader silencing triggers) is captured like any other.
The reconcile is bounded by the same budget as the copy and takes the tick when there is work,
so a burst of DML paces itself rather than landing inside the swap. A pass consumes from the delta exactly
the captured rows it applied, so a change that commits while a pass is running is neither lost nor
consumed early: it stays in the delta for the next pass. If writes outpace it the regrain stalls
at `reconciling:N` rather than swapping: the source stays attached, reads are unaffected, and no unbounded
work is done under the swap's lock.

The swap has the same contract. Whatever is captured between that gate and the moment the `DETACH` takes
its lock is reconciled under the lock until nothing is left, and the source is dropped only once no
captured change in its range remains; if one does, the swap raises rather than drop it, the whole tick rolls
back, the source stays attached with capture still installed, and the next tick reconciles the backlog and
swaps. That residual can be large: a writer that already holds a row in the source keeps the `DETACH`
waiting for as long as its transaction stays open, and everything it commits in that time lands after the
gate. Under `maintain` the `DETACH` gives up after 200 ms (a `skip_regrain` row, retried next tick), which
keeps the residual small; a hand-driven `regrain_step` waits without a timeout, so a large purge committing
during that wait is reconciled under the lock in full.

`TRUNCATE` is the exception, and it is **refused** rather than honoured. It fires no row trigger, so the
rows it removes cannot be captured, and a `TRUNCATE` of the parent never reaches the copies (they are not
partitions until the swap), so the swap would put every truncated row back. While a regrain is in flight, a
`TRUNCATE` of the parent or of the coarse child fails with `pg_partition_magician: cannot TRUNCATE ... a
regrain is in flight on it` before anything is truncated, including from a session with
`session_replication_role = replica`. Cancel the regrain with `regrain_cancel` first, or truncate after the
swap.

The reconcile finds each captured key's fine child by its recorded **range** in `pgpm.part`, not by name,
so a first sub-range that was clamped to the coarse child's own `lo` (a weekly target on a monthly monolith,
whose `lo` is not on the weekly grid) is reconciled into the child that actually exists. A captured key
whose sub-range has **no** fine child is discarded, and logged `regrain_reconcile_aged`, only when that
sub-range lies below the retention horizon, which is the one case in which no child was ever made. In any
other case the tick fails rather than discarding the change, and the key stays in the delta; under
`maintain` that surfaces as a `skip_regrain` row carrying the error.

The first tick installs the capture and copies nothing, so budget one tick more than the microbatch count.

### `regrain_cancel`

```sql
pgpm.regrain_cancel(p_parent regclass) returns int
```

Stops an in-flight regrain and reclaims what it has built, returning the number of in-flight fine children
dropped. It removes change capture (and with it the `TRUNCATE` refusal), clears the delta, drops every
not-yet-attached copy, and resets
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

The per-table tick for everything except `obtain`, which has its own procedure,
[`maintain_obtain`](#maintain_obtain), and its own cron job (see [Scheduling](#scheduling)):
enforce write-blocks on every attached child against the retention boundary, one chunked-archiving
step, `retain`, restore any preserved FK once the table is quiescent, and -- when auto-regrain is on
(`config.regrain_to`) -- one `regrain_step` on the oldest frozen coarse child. A no-op while paused.
Every step runs under a short `lock_timeout` and is isolated from the others, so it never blocks or
deadlocks the live workload, and one step failing does not abandon the rest of the tick; a step that
loses a lock race is deferred and retried next tick.

The write-block step checks each child's name against `pgpm.part.child_oid` before installing anything,
and refuses on a mismatch, logging `fail_write_block_identity` rather than putting a pgpm trigger on a
relation it has not identified. Removal is deliberately *not* anchored: an older pgpm could have left
that trigger on a substituted relation, rejecting every write to it, and removing by name is what lets an
upgraded pgpm lift it off again.

A procedure, and each step commits before the next begins, so no step's locks outlive it. Those commits
mean `maintain` and `maintain_all`, like `transmute`, must be called at the **top level**, never inside
a surrounding transaction; `pg_cron` runs its command as a top-level statement, so the scheduled path
satisfies this for free.

`p_status` reports a one-line summary, for example
`archived=1 dropped=0 restored_fk=0 regrain=copied:5000`. Call
it as `call pgpm.maintain('public.events')` and the summary comes back as a result row; from
PL/pgSQL, pass a variable to receive it.

Write-blocking: a child whose whole range sits at/below the retention horizon
(`_retain_boundary`, the same one `retain` itself uses) gets a `BEFORE INSERT OR UPDATE OR DELETE`
trigger the moment it becomes eligible, independent of whether or how it is archived -- a backdated
write into an eligible-but-not-yet-dropped range (including one a chunked archiver already covered)
is rejected rather than silently diverging the archive from what is live. Loosening `config.retain`
removes the trigger from a partition that becomes ineligible again, **unless `pgpm.archive_ledger`
already records coverage for it**. Coverage is only true of a partition nothing has written to since
it was recorded, so a covered partition keeps its trigger when retention stops reaching it, whether
through a loosened `retain` or, on an `id` table, a frontier that moved back because the newest rows
were deleted. It keeps being archived to completion under the block, and is dropped only if retention
reaches it again. The first tick that keeps a block it would otherwise have lifted logs
`skip_write_block_lift` for that partition, once. To make the partition writable again, delete its
`pgpm.archive_ledger` rows: the next tick lifts the block, and if the partition is ever blocked again
archiving starts over from its `lo`. Coverage a tick finds on a partition that has **no** trigger (one
removed by hand, or lifted by a pgpm older than this rule) is discarded for the same reason and logged
as `archive_coverage_reset` with the number of chunks that went. Write-blocked is one of
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

A procedure that calls `maintain` for every managed table. This is what the `pgpm` scheduled job runs.

### `maintain_obtain`

```sql
call pgpm.maintain_obtain(p_parent regclass, inout p_status text default null)
```

The per-table `obtain` tick, separate from `maintain`: takes `ACCESS EXCLUSIVE` on the
parent under a short `lock_timeout` when it creates a partition, so a lock race is deferred and retried
next tick rather than blocking the live workload; a deferral starts a 30-second
`config.obtain_retry_after` back-off so sustained contention does not retry every tick. The back-off is
honored only while at least `ceil(obtain / 2)` complete grid steps of attached coverage remain beyond the
frontier's own grid cell (coverage, not partitions: grid inside a monolith widened by `p_bound_headroom`
counts): with no `DEFAULT` to catch a write past the grid, a back-off that outlasted the lookahead would
turn a lost lock race into refused writes, so below that threshold obtain runs anyway and the status
notes `obtain_backoff_bypassed`. A no-op while paused, checked independently: it does not assume
`maintain` ran first, or at all, in the same tick. Around `pgpm.obtain()` it is the same operational
wrapper (lock timeout, back-off, exception handling, logging, transaction boundary) that `maintain`
provides for its own steps.

A procedure that commits, so like `maintain` it must be called at the **top level**, never inside a
surrounding transaction; the scheduled path satisfies this for free.

`p_status` reports a one-line summary, for example `obtained=2`. Call it as
`call pgpm.maintain_obtain('public.events')` and the summary comes back as a result row; from
PL/pgSQL, pass a variable to receive it.

### `maintain_obtain_all`

```sql
call pgpm.maintain_obtain_all()
```

A procedure that calls `maintain_obtain` for every managed table, in the same table order as
`maintain_all`. This is what the `pgpm_obtain` scheduled job runs. Unlike `maintain_all`, it does not
run the crash-recovery reaping (`_transmute_reap`/`_detach_reap`) -- `obtain` does not depend on either
having run, and the `pgpm` job still performs them on its own cadence regardless of whether this job
also runs.

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

The core holds a strategy to that promise. Before a ledger row is written from a call's result,
`covered_hi` must be a native grid value strictly above the `p_lo` the call was handed and no greater
than its `p_hi`. A return that breaks this (null, at or below `p_lo`, past `p_hi`, or not a native
value at all) is not recorded: the step logs one `fail_archive_contract` row naming the strategy, the
chunk, the value returned and the rule it broke, skips that partition for the tick, and counts the
refusal in `status().retain_drop_failures`; see
[the archive step's contract check](#the-archive-steps-contract-check). A strategy that cannot make
progress on a call (the object store is unreachable, say) should **raise** rather than return:
`maintain()` records that as a `skip_archive` deferral and hands it the same chunk next tick, which
is the retry path. Returning `p_lo` as `covered_hi` is not.

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
built-in way to drive the contract above without hand-writing a resumable `archive_fn`. It is a
byte-budget chunker: never archive a whole large partition as one giant operation, chunk it instead.

- `config.archive_byte_budget` (default 8 MiB) and `config.archive_probe_sample` (default 1000)
  estimate how many rows fit the budget via a sampled average row width.
- **Raising `archive_byte_budget` raises how long the tick's `archive_fn` call runs for, and
  `pgpm.maintain()` applies no timeout of its own to that call.** With `pgpm.archive_to_s3_parquet`
  and `archive.config.compress` on, that time is dominated by `pgpm_archive`'s own from-scratch
  GZIP writer, pure PL/pgSQL and CPU-bound: real compression time runs from ~50ms/MB on
  compressible data up to ~2.6s/MB on near-incompressible data (see
  [`pgpm_archive/README.md`](../pgpm_archive/README.md#ndjson-or-parquet)), scaling roughly linearly
  with the budget. An 8 MiB budget is already several seconds of CPU on the low end of that range;
  doubling it can double the tick's duration and cross whatever `statement_timeout` the connection
  running `maintain()` has, surfacing as the tick failing outright rather than as a slow tick.
  Size `archive_byte_budget` with that per-MB cost and the maintaining session's
  `statement_timeout` in mind, not just S3 part-size or file-count preferences -- if a tick is
  timing out, lowering `archive_byte_budget` (or turning `compress` off, or switching to
  `pgpm.archive_to_s3_ndjson`) is the fix, not raising any lock or statement timeout.
- `pgpm.archive_ledger` (`parent_table`, `lo`, `hi`, `child_name`, `s3_key`, `etag`, `rows_archived`,
  `archived_at`) records one row per chunk. `s3_key`/`etag` come straight from the `archive_fn` call's own
  `pgpm.archive_result` -- populated for a real transport strategy, still `null` for a
  strategy with nothing object-store-shaped to name (`pgpm._archive_noop`, the `none` strategy).
- `pgpm._next_archive_chunk(p_parent, p_child)` picks the next chunk **within one child's own
  `[lo, hi)`** -- resuming from wherever that child's ledger coverage left off, extended to the next
  distinct control value so a run of ties never splits across two chunks. It only ever looks at a
  child that is already write-blocked, and the block is not lifted while the ledger covers the child
  (see [`maintain`](#maintain)), so what it archives cannot change underneath it.
- `pgpm._archive_fully_covered(p_parent, p_child)` is true once the ledger's recorded ranges for
  that child reach its own `hi` (or the strategy is `none`) -- `retire()`'s archive-coverage drop
  precondition (see [`retire`](#retire)).
- `pgpm._archive_step(p_parent)`, called once per `maintain()` tick, is the orchestrator: among
  attached children that **already have the write-block trigger installed** (checked directly, not
  re-derived from the boundary formula) and are not yet fully covered, it picks up to
  `config.archive_batch` of them, **oldest first**, and for each picks the next chunk, runs
  `_run_archive_strategy`, checks the returned `covered_hi` against that chunk (see
  [the archive step's contract check](#the-archive-steps-contract-check)), and records the result in
  `pgpm.archive_ledger`. A child without the trigger yet is never touched, however far past the byte
  budget's reach it sits.
- `config.archive_batch` (default **1**; `null` = unbounded) caps how many *different* partitions
  one `_archive_step` call touches -- the same shape as `retain_batch` (nullable `int`, `null`
  means unlimited, caps attempts not successes), but a different default, and for a reason worth
  spelling out: `retain_batch`'s unlimited default is safe because its unit of work, `DROP TABLE`,
  is cheap and roughly constant-cost regardless of how many run per tick. Archiving's unit of work
  is not -- each partition costs a real table read, an encode pass, and, with a real S3 strategy and
  `archive.config.compress` on, a CPU-bound compression pass (see the note on `archive_byte_budget`
  above). Fanning out over every eligible partition in one tick makes a single `maintain()` call's
  duration scale with the size of the *backlog*, not just with `archive_byte_budget`'s own
  per-partition cost -- invisible in steady state (one partition becomes eligible per rollover
  interval), but very visible the moment a bulk regrain or backfill leaves many partitions
  simultaneously eligible at once, at which point the aggregate cost can cross `statement_timeout`
  regardless of how conservatively the per-partition budget is tuned. Defaulting to `1` makes
  archiving strictly sequential: one partition fully archived, and so retirable, before the next is
  even touched. Raise it, or set it `null`, if a large backlog catching up faster matters more than
  that bound.
- **`archive_batch` and `archive_byte_budget` are fungible for speed and risk, but not for file
  shape.** Per-tick duration is roughly `archive_batch x archive_byte_budget x (cost per byte)`
  (compression scales close to linearly with chunk size), and so is how many ticks it takes to
  clear a backlog: `_archive_step`'s query is a sliding window over the oldest not-yet-covered
  partitions, so total chunk-advancements needed is fixed and each tick contributes `archive_batch`
  of them. Both quantities depend on the same product, so `archive_batch=1` with a bigger budget
  and `archive_batch=N` with a smaller one, chosen so the product matches, land on roughly the same
  per-tick duration and the same backlog-convergence speed. They are NOT interchangeable for the
  *shape* of what gets uploaded: `pgpm._next_archive_chunk` reads only `archive_byte_budget` (never
  `archive_batch`) to decide how many rows make up one chunk, and one chunk is one uploaded file --
  `archive_batch` cannot make files bigger or smaller, or change how many chunks it takes to cover
  one partition, only how many *different* partitions' independent chunk sequences advance in the
  same tick. Pick `archive_byte_budget` first, for the file size (and per-chunk risk) you actually
  want; use `archive_batch` to buy back backlog-convergence speed at that fixed shape, rather than
  raising `archive_byte_budget` alone and reintroducing the per-partition timeout risk to get the
  same speed `archive_batch` would have bought for free on that axis.

#### The archive step's identity check

Every step of archiving works from the partition's **name** out of `pgpm.part`: the chunk is sized from
whatever relation that name resolves to, and `archive_fn` is handed the bare name. So if `child_name` stops
naming the partition it was recorded for -- someone renamed the partition aside, something else took the
name -- the chunk would be sized from whatever now holds it, and the `pgpm.archive_ledger` row that
follows would claim coverage of a range those rows never came from. That ledger is `retire()`'s drop
precondition, so a bad chunk would not merely put a wrong object in the bucket: it would open the gate
that authorises a `DROP`.

So before reading anything about a candidate, `_archive_step` resolves its name and compares the
result to `pgpm.part.child_oid`, recorded when the partition entered the catalog. On a mismatch --
including a name that resolves to nothing at all -- it logs `fail_archive_identity` with both OIDs in
`method` and skips that partition, continuing with the rest of the batch. Nothing is read, so no
ledger row is written, so `_archive_fully_covered` stays false and the drop precondition stays shut.
The write-block step makes the same check before a partition ever becomes an archive candidate (see
[`maintain`](#maintain)); this one is what still catches a trigger an older pgpm left on a
substituted relation.

Like `fail_retain_identity`, the refusal is permanent rather than retryable: no later tick makes the
name mean the right relation again. It counts in `status().retain_drop_failures`, and shows up as
`retain_backlog` flat while that count climbs. Recovery is an operator decision -- put the intended
relation back under that name, or clear the stale row with
[`forget_missing`](#forget_missing). At `archive_batch`'s default of `1` a wedged partition also
holds up that parent's other partitions, which is deliberate: pgpm's catalog is demonstrably wrong
about which relation is which, and retention should not march on past that. A null `child_oid` (a
partition recorded before the column existed, whose name no longer resolved at upgrade time) is
unanchored and skips the check entirely.

#### The archive step's contract check

`archive_fn`'s return is a claim about the chunk it was handed, and the `pgpm.archive_ledger` row
written from it is what opens `retire()`'s drop gate. Recorded verbatim, a strategy that answered
chunk `[0, 15)` with `covered_hi = 15000` marked the whole partition covered on the spot, and the next
`retain()` dropped it with nothing archived. So before writing the row, `_archive_step` checks the
returned `covered_hi` against the `[p_lo, p_hi)` it passed: it must be a native grid value with
`p_lo < covered_hi <= p_hi`.

Each bound closes a different hole. Past `p_hi` is the drop with nothing archived. At or below `p_lo`
is "no progress", which recorded as a `(lo, lo)` ledger row wedged the ledger for good: the next tick
resumed from `max(hi) = lo`, handed the strategy the same chunk, and collided on the ledger's primary
key, every tick from then on. A null `covered_hi` is refused for the same reason (a null `hi` is not a
watermark). And a value that is not a native value at all is refused here rather than left in the
text `hi` column, where every later coverage check would have raised, and `maintain()` would have
reported that as a `skip_archive` deferral, tick after tick, for what is a permanent strategy bug.

On a breach nothing is recorded. The step logs `fail_archive_contract`, with the strategy, the chunk,
the value it returned and the rule it broke in `method`, skips that partition for the tick, and
continues with the rest of the batch. Coverage stays exactly where it was, so the drop precondition
stays shut. It counts in `status().retain_drop_failures`, and at `archive_batch`'s default of `1` it
also holds up that parent's other partitions, which is right: the strategy is demonstrably wrong
about what it archived.

Unlike the identity refusals, this one is retryable by construction. Nothing advanced, so the next
tick hands the strategy the very same chunk; correct the strategy (or point `pgpm.set_archive_fn` at
a corrected one) and archiving resumes from where the ledger honestly stands. Until then the row
repeats once per tick. A strategy that genuinely cannot make progress on a call should raise rather
than return `p_lo`: a raise is logged as `skip_archive` and retried with the same chunk, and says
what it is.

#### Sizing `archive_byte_budget`: there is no single optimal size

Four considerations pull in different directions, and no formula resolves all of them at once --
picking a value is a tradeoff, not a lookup.

1. **A floor, from the Parquet writer's compression window.** Its compression only benefits from
   content that repeats within roughly 32 KB *of a single column's own data stream*; repetition
   further apart than that compresses as if it were unique. A chunk should be big enough to
   comfortably clear this floor for whatever repetition actually exists in the data, or cheap
   compression is left on the table. For ordinary tabular data this floor is low (a few hundred KB
   to low single-digit MB) and rarely the binding constraint on its own.
2. **A ceiling, from `statement_timeout`.** As the note above on `archive_byte_budget` describes,
   `_archive_step`'s per-tick call has no timeout of its own. With compression enabled, real
   measurement across several row counts on a synthetic table showed per-chunk time growing
   somewhat faster than the byte budget itself -- not dramatically, but enough that doubling the
   budget should be expected to more than double a chunk's processing time, not exactly double it.
   Treat the roughly-linear estimate above as an optimistic floor, not a guarantee, and measure a
   real chunk at the actual table's scale before sizing a budget close to `statement_timeout`.
3. **A query-pattern consideration: a query engine can skip whole files, never part of one.** The
   files the writer produces carry nothing Athena, DuckDB, or similar engines can use to skip
   *within* a file (see [`pgpm_archive/README.md`](../pgpm_archive/README.md#limits)); the only
   pruning available is by file, through naming or partitioning. Broad-scan workloads (queries that
   touch most or all of the archived history) are indifferent to this and benefit from fewer,
   bigger files (less per-file open/list overhead). Selective, range-scoped workloads (e.g. "just
   last month") are hurt by oversized files: a query touching a fraction of a file still pays to
   scan the whole thing. These two workload shapes want opposite answers -- there is no way to pick
   one without knowing which describes the actual query pattern.
4. **A minimum-count consideration, from S3/Athena's own per-file overhead.** Too many small files
   costs real list/open/task overhead in the query engine, independent of everything above -- this
   is the one consideration that is a fairly universal "not too small," rather than
   workload-dependent.

**Tie the budget to a meaningful boundary, not an arbitrary byte count.** The most useful sizing
method is not a number, it's a way of picking one:

- Size `archive_byte_budget` against a boundary that is already meaningful to the retention/query
  granularity in use -- e.g. "one managed partition archives in as few chunks as
  `statement_timeout` safely allows, ideally one" -- rather than picking a byte target divorced
  from how the data is organized. This gives files that line up with the one pruning mechanism
  these query engines actually have (file-level, via naming), for free.
- Measure the actual per-row cost and compressibility rather than assuming them. Pull an
  already-archived file's size against its `rows_archived` (`pgpm.archive_ledger`) for a real
  compression ratio, and time a real chunk (via `pgpm.archive_ledger.archived_at` deltas, or a
  manual timed call) rather than extrapolating from a generic benchmark -- both vary widely with
  actual data shape.
- If a single partition's data is too large to safely fit in one chunk even at a conservative
  budget, accept multiple files per partition rather than forcing one -- `archive_batch`'s
  sequential-by-default pacing already means only that one partition's cost is at stake per tick,
  not the whole backlog's.
- Prefer raising `archive_batch` over `archive_byte_budget` to recover throughput when both are
  options: `archive_batch`'s effect on total tick time is linear (it multiplies independent,
  separately-sized chunk operations), while `archive_byte_budget`'s effect on a single chunk's own
  cost is somewhat worse than linear whenever compression is enabled (consideration 2 above). The
  same throughput gain carries less risk when bought via `archive_batch` than via
  `archive_byte_budget`.

**The ~1 GiB Postgres `bytea` ceiling documented in
[`pgpm_archive/README.md`](../pgpm_archive/README.md#limits) is not the ceiling that binds in
practice.** The whole encoded file is held in memory before upload, capping it at roughly 1 GiB, but
reaching that in one synchronous call is measured to take on the order of many minutes at minimum
with compression on -- `statement_timeout` is reached first, by orders of magnitude, under any
realistic timeout setting. The 1 GiB figure is real but should not factor into how
`archive_byte_budget` actually gets sized; `statement_timeout` does.

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
pgpm.schedule(p_every text default '* * * * *', p_obtain_every text default '* * * * *') returns bigint
```

Creates (or replaces) the `pg_cron` job named `pgpm` that runs `call pgpm.maintain_all()` on the
`p_every` cron schedule in the current database, returning the job id. One job covers every managed
table and is idle while they are paused. Raises if `pg_cron` is not installed.

It also creates a second job, `pgpm_obtain`, that runs `call pgpm.maintain_obtain_all()` on its own,
independent `p_obtain_every` cron schedule. obtain has its own job because it is the one step where
falling behind has a hard consequence: with no `DEFAULT` partition, a write past the forward grid is
rejected outright, not queued, and a slow archive/retain/regrain for one table would otherwise delay
obtain for every table after it in the same tick. `pgpm.maintain()` itself does not obtain at all.

**Upgrade hazard.** `schedule()` is operator-invoked, never automatic. If you already called
`pgpm.schedule()` before upgrading to a version with this split, re-run it once -- the new `pgpm_obtain`
job is not created for you, and without it obtain will not run at all until you do, silently, until the
forward grid runs out and writes start failing. `maintain_all()` also logs a `warn_obtain_unscheduled`
row to `pgpm.log` once per sweep as a backstop for anyone who misses this.

It also creates a third job, `pgpm_detach`, on the `p_every` schedule and **idle** (`select 1`). That one
is machinery for the referenced-partition path: `retire` rewrites its command in place when a partition
an incoming foreign key references needs detaching, and returns it to idle once the drop lands. Leave it
alone: an idle `select 1` is its normal state, and retiring a referenced partition does not work
without it.

### `unschedule`

```sql
pgpm.unschedule() returns int
```

Removes the `pgpm`, `pgpm_obtain` and `pgpm_detach` cron jobs (returns the number removed, so `3` for a
fully scheduled install; `0` if `pg_cron` is absent or nothing was scheduled).

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
reason not to leave it: PostgreSQL reuses oids, so a stale row is a standing chance of pgpm one day
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

Turn auto-regrain on or off. A non-null `p_target_step` (an interval as text for time/uuidv7/text_time, a `bigint`
step as text for id) lets each `maintain` tick feather the oldest frozen coarse child one microbatch
toward that granularity; `null` turns it off (regrain stays operator-driven). Enabling it is always safe:
`regrain_step` enforces its own preconditions, so an un-meetable tick simply retries.

### `set_obtain`

```sql
pgpm.set_obtain(p_parent regclass, p_obtain int) returns void
```

Change `config.obtain`, the number of partitions `obtain` keeps built ahead of the write frontier.
Refuses a negative `p_obtain`, which would otherwise silently and permanently disable lookahead with
nothing raised. `0` is allowed (no lookahead beyond the partition the frontier is already in).

### `set_retain`

```sql
pgpm.set_retain(p_parent regclass, p_retain text default null) returns void
```

Change `config.retain`, the retention horizon `retain()` drops partitions past (`null` = keep forever).
`p_retain` is validated against `control_kind` the same way `transmute` does: `numeric` for `id`, an
interval for `time`/`uuidv7`/`text_time`, and, like `transmute`, it must not be negative. A negative
value is refused outright, whatever the current value: it puts the horizon past the partition taking
writes, and the guard below compares boundaries, so on its own it cannot see a value that grid-floors to
the current boundary. `'0'` is allowed and keeps only the partition taking writes.

`retain` is the destructive knob -- it decides what gets `DROP`ped -- so `set_retain` **refuses**,
rather than warns, whenever the new value would make the very next `retain()` tick drop a partition
the *old* value still kept. The check runs before anything is written. Loosening (a larger
interval/count, or `null`) can never trip it: a wider horizon only ever keeps a superset of what a
narrower one kept. A tighter value that happens to grid-floor to the same boundary as before (nothing
newly eligible) is also allowed -- the refusal is about what would actually drop, not the raw number.

Loosening does not reopen a partition that chunked archiving has already begun to cover: its write
block stays, it is archived to completion, and the tick that keeps the block logs
`skip_write_block_lift` once. See write-blocking under [`maintain`](#maintain) for why, and for how to
make such a partition writable again.

Loosening while a regrain is in flight (`config.regrain_cursor` set) raises a **warning**, not a refusal.
Sub-ranges that regrain has already skipped as aged under the old value are re-checked against the new
one at the swap (see [`regrain_step`](#regrain_step)), which refuses while any of them is no longer below
the horizon. The change itself is safe; the swap waits until `retain` is set back or the run is
cancelled with [`regrain_cancel`](#regrain_cancel).

### `set_partition_tz`

```sql
pgpm.set_partition_tz(p_parent regclass, p_tz text) returns void
```

Change `config.partition_tz`, the zone the grid is computed in and partition names are rendered in.
`transmute` records the transmuting session's `TimeZone` there and every later boundary is computed in
it whatever zone the maintaining session runs in, so this is normally never called. It exists for the
upgrade case: an install that predates the column has it backfilled to `UTC`, and a table whose grid was
built from a non-UTC session has to be told which zone that was.

`p_tz` must be a name in `pg_timezone_names` (any casing; the canonical spelling is stored). An `id` grid
is refused: it has no calendar and never reads the zone. A change is **refused** when the newest
partition's upper bound is not a grid boundary in the new zone, because `obtain` would then skip every
candidate that half-overlaps the current tail and create the first one past it, leaving a permanent
hole. A day-denominated step is the same lattice in every zone, so its zone can always change (only the
names move); a month or year step can only be moved to the zone the grid was in fact built in. Each
accepted call writes a `set_partition_tz` row to `pgpm.log` with `old -> new` in `method`.

## Observability

### `status`

```sql
pgpm.status() returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text, fks_suspended bigint, fks_unvalidated bigint,
  history_unregrained boolean, retain_drop_failures bigint, retain_backlog bigint,
  retain_detaching bigint, parent_missing boolean, regrain_to text
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
  one and the FK's own `ON DELETE` refused the delete), `fail_retain_detach` (nowhere to dispatch a
  concurrent detach to), `fail_retain_identity` (the partition's name no longer resolves to the
  relation whose detach was dispatched), `fail_archive_identity` (the same mismatch found one step
  earlier, by the archive step, so coverage never completes and the drop gate never opens) and
  `fail_write_block_identity` (the same mismatch one step earlier again, so the partition never
  becomes an archive candidate at all) and `fail_archive_contract` (the archive step refused a
  strategy's returned `covered_hi` that broke the contract, so coverage does not advance), since all
  seven wedge retention the same way.
- `parent_missing` -- the managed relation itself is **gone**: dropped without
  [`untransmute`](#untransmute), leaving the `pgpm.config` row pointing at an oid that no longer
  resolves. Everything else in the row still reports (it comes from pgpm's own catalog), but
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
- `regrain_to` -- the auto-regrain target step (`config.regrain_to`), null when auto-regrain is off.
  Whether the history is being split at all is the first thing to check when `coarse_partitions` looks
  stalled, and it is here so that check needs no second query.

### `progress`

```sql
pgpm.progress(p_parent regclass default null) returns table (
  parent regclass, control_kind text, parent_missing boolean,
  frontier text, write_child name, write_ceiling text, freeze_margin text, freeze_in interval,
  coarse_frozen bigint,
  regrain_to text, regrain_child name, regrain_cursor text, regrain_pct_range numeric,
  regrain_rows_copied bigint, regrain_rows_total_est bigint, regrain_delta_pending bigint,
  regrain_started_at timestamptz, regrain_elapsed interval, regrain_eta interval
)
```

The drill-down `status` is not: one table's position in the transmute, freeze, regrain sequence. One row
per managed table, or just `p_parent`'s (an unmanaged table is refused by name rather than answered with
no rows). It answers two questions that otherwise need `pgpm.part`, `pgpm.config`, `pgpm.log` and the
grid arithmetic by hand.

**When will the monolith freeze?** A coarse child can only be regrained once the frontier has moved past
its upper bound, and that bound is what the anchor, the step and any `p_bound_headroom` actually
produced, not what you meant them to.

- `frontier` -- the write frontier in native terms: `now()` for `time`, `max(control)` for `id`,
  `greatest(max(control), now())` for `uuidv7` and `text_time`.
- `write_child` / `write_ceiling` -- the attached partition the frontier sits in, and its upper bound.
  While `write_child` is the monolith, it has not frozen. Null if the grid has fallen behind the frontier.
- `freeze_margin` -- `write_ceiling - frontier`: an interval for the time-grid kinds, a count for `id`.
- `freeze_in` -- the same margin as an `interval`, **only for `time`, `uuidv7` and `text_time`**, whose
  frontier is a clock and so makes this plain arithmetic. For `id` it is **null**: the frontier is
  `max(control)`, pgpm keeps no history of it, and a rate to divide by would be a guess. Read
  `freeze_margin` instead.
- `coarse_frozen` -- coarse partitions whose whole range is already behind the frontier: frozen, and
  eligible for regrain. `coarse_frozen > 0` beside a null `regrain_to` is a history that is not going to
  split by itself.

**How far along is the regrain, and when does it finish?** Populated while a regrain is in flight
(`config.regrain_cursor` set, and one child carrying change capture); null otherwise.

- `regrain_child` / `regrain_cursor` -- the coarse child being split, and the native lower bound of the
  sub-range currently being copied. The cursor only ever advances, one sub-range at a time.
- `regrain_pct_range` -- `(cursor - lo) / (hi - lo)`: the exact fraction of the child's **range** behind
  the cursor. This is not a row fraction. The cursor moves only when a whole sub-range completes, so it
  sits still while rows pile up in a large one, and a below-horizon sub-range is advanced over without
  being copied, so it can jump ahead of the rows. Read it alongside `regrain_rows_copied`.
- `regrain_rows_copied` -- rows copied by this run, exact, summed from its `regrain_copy` log rows.
- `regrain_rows_total_est` -- `reltuples` of the source child. An estimate, counting every row in the
  source including those in aged sub-ranges that will never be copied; null until the child has been
  analyzed. There is deliberately no fused "N of M rows" figure, because one cannot be produced honestly
  without a full scan.
- `regrain_delta_pending` -- captured changes not yet reconciled. A regrain that returns `reconciling:N`
  tick after tick is waiting on this to fall below `regrain_batch`. Populated whether or not a regrain is
  in flight (0 when idle).
- `regrain_started_at` / `regrain_elapsed` -- when this run's `regrain_prepare` was logged, and how long
  ago that was.
- `regrain_eta` -- `elapsed * (1 - pct_range) / pct_range`: extrapolated from the range fraction observed
  so far, so it inherits that fraction's caveats. **Null until `regrain_pct_range > 0`**, which is the
  whole of the first sub-range: there is nothing to extrapolate from yet, and pgpm does not invent a
  figure.

```sql
select write_child, freeze_in, coarse_frozen, regrain_to from pgpm.progress('public.events');
select regrain_pct_range, regrain_rows_copied, regrain_eta from pgpm.progress('public.events');
```

A parent dropped without [`untransmute`](#untransmute) is reported with `parent_missing = true` and every
frontier-derived column null, the same way `status` does, rather than taking the whole row set down.

### `check_uuidv7`

```sql
pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
  returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz,
                 newest_decoded timestamptz, newest_in_future boolean)
```

Samples a `uuid` column and reports the fraction whose decoded 48-bit timestamp prefix is a plausible
recent time. Genuine UUIDv7/ULID scores `~1.0`; random UUIDv4 scores `~0`. A heuristic, not a proof; this
is the check `transmute` runs to gate the uuidv7 kind.

`sampled`, `plausible`, `fraction`, `oldest` and `newest` describe the **sample**. `newest_decoded` does
not: it is the column's actual maximum, found the way `transmute` finds its frontier and decoded, and
`newest_in_future` is whether that maximum sits more than one hour past `now()`. Look at these before
converting: a single future-dated row (a client with a wrong clock) leaves `fraction` at `0.99+` and can
still pin the monolith's permanent `hi` years out, which is why `transmute` refuses one that leads the clock
by more than one partition step plus one hour (see [`p_force_frontier`](#transmute-time--uuidv7--text_time-grid)).
Rows to delete or correct are the ones sorting above `pgpm._ts_to_uuid(now() + <step> + interval '1 hour')`.

### `check_text_time`

```sql
pgpm.check_text_time(p_table regclass, p_control name, p_prefix text, p_width int, p_radix int,
                      p_unit text, p_sample int default 1000,
                      p_alphabet text default null, p_discard_bits int default 0,
                      p_epoch timestamptz default '1970-01-01 00:00:00+00')
  returns table (sampled bigint, plausible bigint, fraction numeric,
                 newest_decoded timestamptz, newest_in_future boolean)
```

The `text_time` analogue of `check_uuidv7`: samples a `text`/`varchar` column against a *declared* shape
(the same `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit` `transmute` takes) and reports the fraction
that both match the shape and decode to a plausible recent time. A value that does not even match the
shape counts as implausible directly, rather than raising -- one malformed row must not abort the sample.
A heuristic, not a proof; this is the check `transmute` runs to gate the text_time kind.

`newest_decoded` and `newest_in_future` are [`check_uuidv7`](#check_uuidv7)'s: the column's actual maximum
(not the sample's), decoded, and whether it sits more than one hour past `now()`. A maximum that does not
match the declared shape reports `null` rather than raising. Rows to delete or correct before a refused
`transmute` are the ones sorting above
`pgpm._ts_to_text_time(now() + <step> + interval '1 hour', <prefix>, <width>, <radix>, <unit>, ...)`.

Refuses, with the same message `transmute` gives, when the control column's collation does not order the
declared alphabet the way base-`p_radix` place value does (a mixed-case alphabet such as KSUID's base62
on an `en_US` column). That is not a heuristic and no fraction is reported: RANGE bounds on a `text`
column compare under the column's collation, so any such column would route rows to the wrong
partition. The message names the collation (the effective database locale when the column is on the
default), the first misordered digit pair and the remedy, `alter table ... alter column ... type text
collate "C"`.

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
pgpm.restore_incoming_fks(p_parent regclass, p_ids bigint[] default null) returns int
```

Re-adds each dropped preserve-managed FK against the new parent, returning the number re-added. Self-gates
on quiescence: a no-op while an in-flight, not-yet-attached regrain child remains.

`p_ids` restricts the re-add to specific `pgpm.dropped_fk.id` values instead of every not-yet-restored row
for the parent. Operators calling this directly should leave it at the default (`null`, restore
everything); it exists for regrain's own swap, which restores exactly the keys it suspended and leaves
any other unrestored FK for the next tick.

It re-adds each FK `NOT VALID` and **stops there**. `NOT VALID` already enforces every *new* write, so
referential integrity is live the moment this returns; only pre-existing rows are unverified, which
`status().fks_unvalidated` reports. `maintain` finishes the validation on a later tick.

That split is deliberate. The re-add briefly blocks writes to **both** the referencing table and the
managed parent; validating in the same statement would hold that block across a full scan of the
referencing table, so writes to your managed table would stall for a time set by a table pgpm does not
own. Split, the blocking part is instant and the scan runs later under a lock that blocks no writes.

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
pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false) returns int
```

The inverse of restore: re-drops every live preserve-managed FK on the parent, returning how many. Its one
caller is regrain's swap, which passes `p_force => true` and restores the same keys inside the same
transaction, so no other session ever observes referential integrity off; a live `ON DELETE CASCADE` or
`SET NULL` would otherwise silently delete or null referencing rows as their referent left the parent.
Without `p_force` it does nothing. There is no reason for an operator to call it.

## Catalog

All `pgpm` state lives in these tables. Treat them as read-mostly; use the functions above to mutate them.

### `pgpm.config`

One row per managed table (`parent_table` is the primary key). Columns:

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the managed partitioned parent |
| `control_column` | `name` | the partition-key column |
| `control_kind` | `text` | `time`, `id`, `uuidv7`, or `text_time` |
| `partition_step` | `text` | grid width (`1 month` for time/uuidv7/text_time; a bigint for id) |
| `partition_anchor` | `text` | grid origin |
| `partition_tz` | `text` | the zone boundaries are computed in and names rendered in: the transmuting session's `TimeZone` (`UTC` for id); change it only with [`set_partition_tz`](#set_partition_tz) |
| `obtain` | `int` | partitions kept ahead of the frontier |
| `retain` | `text` | retention horizon (interval for time/uuidv7/text_time, bigint count for id; null = keep) |
| `retain_batch` | `int` | max partitions one `retain()` call attempts, oldest first (null = unbounded) |
| `regrain_batch` | `int` | rows per regrain COPY microbatch |
| `paused` | `boolean` | maintenance is idle while true |
| `created_at` | `timestamptz` | when transmuted |
| `obtain_retry_after` | `timestamptz` | back-off marker after an obtain lock-race deferral |
| `regrain_max_blocks` | `int` | optional block budget per microbatch (caps wide rows; null = row cap only) |
| `regrain_to` | `text` | auto-regrain target step (null = off; see `set_regrain`) |
| `regrain_cursor` | `text` | how far the in-progress regrain has copied (null = not regraining); [`progress`](#progress) reads it as a fraction of the range |
| `archive_fn` | `regprocedure` | the pluggable archive strategy (null = `none`); see [Archive strategy contract](#archive-strategy-contract) |
| `archive_byte_budget` / `archive_probe_sample` | `bigint` / `int` | byte-budget chunking knobs for the built-in chunked archiver (see [Byte-budget chunked archiving](#byte-budget-chunked-archiving)) |
| `archive_batch` | `int` | max partitions one `_archive_step` call touches, oldest first (default 1; null = unbounded -- see [Byte-budget chunked archiving](#byte-budget-chunked-archiving)) |
| `text_time_prefix` / `text_time_width` / `text_time_radix` / `text_time_unit` | `text` / `int` / `int` / `text` | the declared shape for a `text_time` control column (null for every other kind); see `p_tt_prefix` etc. above |
| `text_time_alphabet` / `text_time_discard_bits` / `text_time_epoch` | `text` / `int` / `timestamptz` | non-default digit set, bits to discard, and epoch for a `text_time` column (null/0/Unix epoch for cuid/ULID-shaped ones; see `p_tt_alphabet` etc. above) |

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
| `retiring_oid` | `oid` | which relation that dispatch meant. The detach travels to pg_cron as text naming the partition, and is re-resolved there; this is what lets `retire` refuse to act when the name has stopped resolving to it (see [identity](#what-retire-checks-a-partitions-identity-against)). Null alongside a null `retiring_at`, and for a retirement already in flight when the column was added |
| `child_oid` | `oid` | which relation this row is about, recorded where the partition enters this table (`obtain`, regrain's standalone child, `transmute`'s monolith) rather than at retirement. The write-block step checks `child_name` against it before issuing any DDL, the archive step checks it before reading the child (see [the archive step's identity check](#the-archive-steps-identity-check)), and `retire` checks it before any side effect -- which is what anchors the ordinary one-step `DROP` that `retiring_oid` leaves uncovered (see [identity](#what-retire-checks-a-partitions-identity-against)). A rename does not change an OID, so regrain's own transitional rename leaves it correct. Null reads as unanchored; an upgrade backfills it for every row whose name still resolves |

Primary key `(parent_table, child_name)`. The non-overlap invariant holds over `attached = true` rows
only; an in-flight child may transiently sit inside a still-attached coarse child.

### `pgpm.log`

An append-only audit trail. `lo`/`hi` are native bounds, `method` a free-text detail, `rows` a count.

**Non-success events are prefixed, never suffixed.** A step that was deferred logs `skip_<mechanism>`
and one that failed logs `fail_<mechanism>`, so no non-success action is ever a prefix-extension of the
success it corresponds to. So `action like 'skip_%'` gives every deferral across all mechanisms without
having to enumerate them, and no failure can hide inside a prefix match on a success the way a suffixed
`retain_skip` would hide inside `retain%`. Prefer exact values regardless: `action = 'obtain'`, not
`action like 'obtain%'`, which would also match whatever is added later.

`action` vocabulary:

| Action | When |
|---|---|
| `transmute` / `untransmute` | conversion and its reversal |
| `transmute_resume` | a conversion resumed mid-flight from its recorded bound (crash/restart between phases), rather than starting over |
| `transmute_abort` | a half-finished conversion undone by an explicit `transmute_abort()` call; `method` records that the bound was dropped |
| `transmute_reap` | the same cleanup as `transmute_abort`, but automatic: `maintain_all`'s sweep found an abandoned in-flight conversion (the session that claimed it is gone) and undid it itself |
| `obtain` | a forward partition created (`method` = `plain`) |
| `retain_drop` | a partition dropped by retention (via `retain()` or `retire()`) |
| `retain_detach` / `retain_crossing` / `detach_reap` | a concurrent detach dispatched for a referenced partition / rows deleted to honour a crossing FK's declared `ON DELETE` / an abandoned concurrent detach finalized |
| `regrain_copy` / `regrain_aged` / `regrain_attach` / `regrain` | a regrain microbatch copied rows into a fine child / skipped a below-horizon sub-range that has no fine child yet (only when `archive_fn` is unset; discarded with the source, never copied, once the swap has re-checked that it is still below the horizon) / attached a fine child (`method` = `check_skip`) / completed (`method` = `copy_swap_drop`) |
| `regrain_prepare` / `regrain_capture_orphan` / `regrain_reconcile` / `regrain_reconcile_aged` / `regrain_rename` / `regrain_restart` / `regrain_cancel` | the cross-tick regrain's own steps: change capture installed / a leftover capture table cleared / the source-is-authority reconcile before the swap (and its below-horizon counterpart) / the source renamed onto the target grid / a stale run restarted / a run cancelled by `regrain_cancel()` |
| `drop_incoming_fk` / `suspend_incoming_fk` / `restore_incoming_fk` / `validate_incoming_fk` | preserve-FK lifecycle events |
| `from_hypertable_carry_fk` | (`pgpm_hypertable` only) an outgoing FK re-added onto the migrated destination during `from_hypertable_copy` |
| `forget_missing` | `forget_missing()` cleared a parent's registration because its relation no longer exists; `rows` carries how many partition rows were cleared with it |
| `archive_coverage_reset` | `pgpm.archive_ledger` rows for a partition were found with no write block on it and discarded, since coverage nothing has been guarding cannot be trusted; `rows` carries how many chunks. Archiving starts over from the partition's `lo` once it is blocked again (see [`maintain`](#maintain)) |
| `warn_obtain_unscheduled` | logged at most once per `maintain_all` sweep, with a null `parent_table`, when the `pgpm` cron job exists but `pgpm_obtain` doesn't -- obtain is silently not running |
| `skip_obtain` / `skip_retain` / `skip_regrain` / `skip_regrain_capture` / `skip_archive` / `skip_write_block` / `skip_restore_fk` / `skip_validate_fk` | a step deferred (lock race or transient error; `method` carries the reason) |
| `skip_write_block_lift` | a partition retention no longer reaches kept its write block, because `pgpm.archive_ledger` already covers it and that coverage is only true while nothing can write to it. Logged once per partition, on the first tick that would otherwise have lifted the block; `method` says how to make the partition writable again (see [`maintain`](#maintain)) |
| `fail_restore_incoming_fk` / `fail_validate_incoming_fk` | a preserve-FK re-add failed / a validation was blocked by an orphan |
| `fail_retain_drop` / `fail_retain_detach` / `fail_retain_crossing` / `fail_detach_reap` | an unexpected `DROP` failure / no `pgpm_detach` job to dispatch the detach to (run `pgpm.schedule()`) / a `NO ACTION`/`RESTRICT` FK blocked the crossing delete / finalizing an abandoned detach failed. In every case the partition is left whole and `method` carries the error |
| `fail_retain_identity` / `fail_archive_identity` / `fail_write_block_identity` | a partition's name no longer resolves to the relation pgpm recorded for it, so `retire` refused to detach or drop it (see [identity](#what-retire-checks-a-partitions-identity-against)) / the archive step refused to read it (see [the archive step's identity check](#the-archive-steps-identity-check)) / the write-block step refused to put its trigger on it. `method` names the OIDs and, for the first, which anchor disagreed. None clears itself on a later tick |
| `fail_archive_contract` | the archive step refused what the archive strategy returned: `covered_hi` was null, not above the chunk's `lo`, past its `hi`, or not a native value, so no ledger row was written and coverage did not advance (see [the archive step's contract check](#the-archive-steps-contract-check)). `method` names the strategy, the chunk, the value returned and the rule it broke. Repeats once per tick until the strategy is corrected, and clears itself once it is |

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

### `pgpm.transmute_inflight`

One row per conversion currently between transactions. Written when `transmute` adds the monolith's bound
and deleted when the cutover commits, so a row that outlives its session is exactly the evidence
`maintain_all`'s sweep and [`transmute_abort`](#transmute_abort) act on. A row here means the table still
carries a `pgpm_monolith_bound` `CHECK` and is refusing writes outside `[lo, hi)`.

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the table being converted (primary key) |
| `nsp` / `rel` | `name` | its schema and name as of the conversion's start, so the bound can still be dropped by name after the rename |
| `control_kind` | `text` | `time`, `id`, `uuidv7` or `text_time` |
| `lo` / `hi` | `text` | the native bounds the `CHECK` is enforcing; a retry reuses these rather than recomputing |
| `started_at` | `timestamptz` | when the conversion added the bound |

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

- time/uuidv7/text_time: `events_p2026_03` (a fine month), `events_p2026_03_to_2026_07` (the monolith)
- id: `events_p0000000000000010000`, `events_p0000000000000000000_to_0000000000000060000`

Day and coarser labels are rendered in `config.partition_tz`. Hour and minute labels are rendered in UTC,
because a zone with daylight saving repeats an hour every autumn and two adjacent cells would otherwise
share a name.

The name is a human-facing label; `pgpm.part` holds the authoritative bounds. The `_to_` form is also
what keeps `transmute`'s orphan check from mistaking a monolith for a leftover of an interrupted regrain.

## Internal adapter layer

Functions named `pgpm._*` are private and may change without notice. The kind-specific logic lives in a
small adapter (`_grid_floor`, `_grid_next`, `_encode`, `_decode`, `_frontier_native`, `_part_name`,
`_native_gt`, `_native_type`), which is where a new partition kind would plug in; the rest (`_transmute`,
`_create_partition`, `_uuid_to_ts`/`_ts_to_uuid`, `_time_literal`/`_col_to_native`/`_canonical_tz`,
`_install_write_block`/`_remove_write_block`/`_enforce_write_blocks`/`_is_write_blocked`,
`_run_archive_strategy`/`_archive_noop`,
`_next_archive_chunk`/`_archive_fully_covered`/`_archive_step`) implements the engine. Do not call
them directly.
