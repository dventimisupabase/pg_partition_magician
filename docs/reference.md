# pg_partition_magician: reference

Complete reference for the public functions, procedures, and catalog objects in the `pgpm`
schema. For task-oriented walkthroughs, see the [user guide](guide.md); for the design rationale,
see [DESIGN.md](../DESIGN.md).

## Conventions

- Everything lives in the `pgpm` schema.
- `p_parent` is always a `regclass` (the partitioned parent, or the table being transmuted). Pass a
  schema-qualified name like `'public.events'`; it is resolved against the current `search_path`.
- "Native" values are a partition kind's internal grid units: `timestamptz` for `time` and
  `uuidv7`, `numeric` for `id`. Partition bounds (`lo`/`hi`) are stored as text in those units.
- The "frontier" is the newest point the table has reached: `now()` for `time`, `max(control)` for
  `id` and `uuidv7`. An interval is "closed" once the frontier has moved past its upper bound; only
  closed intervals are drained.
- Functions raise `pg_partition_magician: ...` (SQLSTATE `P0001`) on misuse.

## Transmutation

`transmute` converts an existing, unpartitioned table into a native `RANGE`-partitioned one, online and
metadata-only. It is one function with two type-safe overloads chosen by the width parameter; within
the time grid, a `uuid` control column is treated as `uuidv7` and a timestamp column as `time`. pgpm
never rewrites the primary key (see [No PK rewrite](#no-pk-rewrite)).

### `pgpm.transmute` (time grid: time / uuidv7)

```sql
pgpm.transmute(
  p_parent       regclass,
  p_control      name,
  p_interval     interval,
  p_obtain      int         default 4,
  p_retain    interval    default null,
  p_keep_default boolean     default true,
  p_drain_batch  int         default 5000,
  p_anchor       timestamptz default '2000-01-01 00:00:00+00',
  p_paused       boolean     default true,
  p_incoming_fks text        default 'error',
  p_drain_adaptive boolean   default false
) returns regclass
```

The interval overload. Within the time grid the control column's type picks the kind: a `uuid` column
is treated as `uuidv7` (ULID-as-uuid included), a `timestamptz` / `timestamp` / `date` column is
`time`. Note this is an assumption, not a detection: PostgreSQL has no UUIDv7 type and v7-ness is not
knowable from the catalog (the column is just `uuid`), so a `uuid` control column is *assumed*
time-ordered and [`check_uuidv7`](#pgpmcheck_uuidv7) samples the data to warn if it looks random (v4)
rather than verifying the type. A bare interval literal is ambiguous against the bigint overload, so
cast it: `transmute(t, c, interval '1 month')`.

| Parameter | Meaning |
|---|---|
| `p_parent` | The table to convert: a plain (unpartitioned) table whose primary key already includes `p_control`, or which has no primary key. |
| `p_control` | The column to range-partition on. |
| `p_interval` | Partition width. Whole-month (`interval '1 month'`, `'1 year'`) aligns to the calendar; fixed-duration (`'1 day'`, `'6 hours'`) tiles from `p_anchor`. Mixing month and duration is rejected. For a `uuid` column it is the time width of each partition. |
| `p_obtain` | How many partitions to keep created ahead of the frontier. |
| `p_retain` | Drop partitions whose upper bound is older than this interval before the frontier. `null` keeps everything. |
| `p_keep_default` | Keep an (expected-empty) `DEFAULT` partition as a safety net. Leave `true`. |
| `p_drain_batch` | Default rows moved per drain microbatch (see `drain_step`). |
| `p_anchor` | Grid origin for fixed-duration intervals. Calendar-aligned months ignore it. |
| `p_paused` | When `true` (default), register but do not let scheduled `maintain` act until you [`resume`](#pgpmpause--pgpmresume). |
| `p_incoming_fks` | `'error'` (default) refuses if other tables have FKs pointing at `p_parent`; `'preserve'` drops each for the conversion, records it, and re-adds it against the new parent once the drain is idle ([`restore_incoming_fks`](#pgpmrestore_incoming_fks)). See [incoming FKs](guide.md#incoming-foreign-keys). |
| `p_drain_adaptive` | When `true`, register with adaptive feathering on (the AIMD self-tuning drain; see [`set_drain_adaptive`](#pgpmset_drain_adaptive)). Default `false` is the fixed-gentle rate. Equivalent to calling `set_drain_adaptive` after transmute, but chosen up front. |

### `pgpm.transmute` (integer grid: id)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 4, p_retain bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_drain_adaptive boolean default false
) returns regclass
```

The bigint overload, for an integer / `bigint` / `numeric` key (including Snowflake-style ids). An
integer literal selects it with no cast: `transmute(t, c, 10000000)`. Differences from the interval form:

- `p_step` is the partition width in key units (e.g. `10000000` ids per partition).
- `p_retain` is a `bigint` count of intervals to keep, not an interval.
- `p_anchor` is a `bigint` grid origin (default `0`).
- The frontier is `max(control)`.

`p_keep_default`, `p_paused`, `p_incoming_fks`, and `p_drain_adaptive` mean the same as in the interval overload.

### What transmute does

Renames the live table to `<name>_default`, creates a partitioned parent under the original name, and
attaches the old table as the `DEFAULT` partition. No rows move. Identity moves to the parent.
Non-unique secondary indexes are carried onto the parent; unique secondary indexes are skipped
(recreate by hand). The transmuted table is registered in [`pgpm.config`](#pgpmconfig) and starts paused;
nothing drains until you [`resume`](#pgpmpause--pgpmresume) it (or drive `drain_*` by hand).

### No PK rewrite

`transmute` never drops or rebuilds the primary key, so the cutover is always metadata-only (no `O(rows)`
index build, ever). It reuses the existing PK in place when `p_control` is already a member of it
(Postgres requires a partitioned PK only to *include* the partition key, not lead it, so a composite
`PK (tenant_id, id)` partitioned by `id` qualifies), and a table with no PK is fine. If the table has
a primary key that does NOT include `p_control` (the classic `events(id PRIMARY KEY, created_at)` that
wants time partitioning), transmute refuses with guidance: make `p_control` part of the primary key first
(a single-column time-ordered key is simplest; or widen the PK yourself via
`CREATE UNIQUE INDEX CONCURRENTLY` then `ALTER TABLE ... ADD PRIMARY KEY USING INDEX`), then re-transmute.

### `pgpm.untransmute`

```text
pgpm.untransmute(p_parent regclass) returns regclass
```

Reverses a `transmute`, while it is still reversible, and returns the restored (un-partitioned) table.
Because `transmute` moves no rows and creates no real partitions (`obtain` does that, later), the
`DEFAULT` partition holds the whole table until maintenance runs, so the conversion can be cleanly
undone: `untransmute` detaches the `DEFAULT`, drops the now-childless parent, renames the `DEFAULT`
back to the original name, and restores what `transmute` changed (identity moves back to the table and
its sequence is reseeded, the drain's autovacuum settings are reset, and any preserved incoming FKs are
re-added). The registration in [`pgpm.config`](#pgpmconfig) is removed.

It is a one-way door the moment a real partition exists. As soon as `obtain` (or `maintain`) has run,
live writes route into real partitions and the drain may have moved rows out of the `DEFAULT`, so the
`DEFAULT` is no longer the whole table; `untransmute` then refuses rather than silently lose the split.
An identity column comes back `GENERATED BY DEFAULT` (`transmute` already normalizes `ALWAYS` to `BY
DEFAULT`, so a round trip is stable), and `p_control` is left `NOT NULL`.

## Maintenance

### `pgpm.maintain_all`

```sql
call pgpm.maintain_all()
```

A procedure that runs `maintain` for every managed table. This is the single entry point you
schedule with `pg_cron`, via [`pgpm.schedule()`](#pgpmschedule--pgpmunschedule) or by hand:

```sql
select pgpm.schedule();   -- or: cron.schedule('pgpm', '* * * * *', 'call pgpm.maintain_all()')
```

### `pgpm.schedule` / `pgpm.unschedule`

```sql
pgpm.schedule(p_every text default '* * * * *') returns bigint
pgpm.unschedule() returns int
```

A thin convenience wrapper around `pg_cron` for the one job pgpm needs. `schedule()` registers a single
job named `pgpm` that runs `call pgpm.maintain_all()` (which covers every managed table), so you
schedule once, not per table; it returns the `pg_cron` job id. `p_every` is a `pg_cron` schedule:
standard 5-field cron (`'* * * * *'` every minute, the default; `'*/5 * * * *'` every 5 minutes) or
pg_cron's seconds interval (`'30 seconds'`). Note pg_cron does **not** accept `'1 minute'`-style
strings; minute cadence uses cron syntax. The job targets `current_database()`, and re-running
`schedule()` updates the interval in place rather than duplicating. `unschedule()` removes it and
returns how many jobs it removed (`0` if none, so it is idempotent).

pgpm never schedules on its own: `transmute` stays `pg_cron`-free, and you can drive the lifecycle by
hand (`drain_all` / `maintain`) with no `pg_cron` at all. Call these **from the database where
`pg_cron` is installed** (its `cron` schema must be present); `schedule()` raises a clear error if
`pg_cron` is absent, and `unschedule()` is then a no-op. `uninstall.sql` removes the job for you.

### `pgpm.maintain`

```sql
pgpm.maintain(p_parent regclass) returns text
```

One maintenance tick for one table: obtain, then retain, then a single `drain_step`. Returns a
short text summary. Respects the `paused` flag (returns `'paused'` and does nothing if paused). Each
step runs in its own subtransaction under a short `lock_timeout`, so a step that loses a lock race is
deferred to the next tick rather than aborting the others; obtain additionally backs off after a
deferral (tracked in `config.obtain_retry_after`).

### `pgpm.pause` / `pgpm.resume`

```sql
pgpm.pause(p_parent regclass)  returns void
pgpm.resume(p_parent regclass) returns void
```

Flip the `paused` flag for one table. `transmute` registers a table paused by default, so going live is
a deliberate step: convert, inspect with [`status`](#pgpmstatus), then `resume`. While paused,
`maintain` is a no-op (`drain_step` / `drain_all` ignore the flag, so you can still drive the drain by
hand). These are the first-class way to set `paused`, so you never hand-edit [`pgpm.config`](#pgpmconfig).
Both raise if the table is not managed.

### `pgpm.obtain`

```sql
pgpm.obtain(p_parent regclass) returns int
```

Creates partitions ahead of the frontier up to `config.obtain`, so live writes always land in a
real partition. Returns the number of partitions created. Uses the scan-skip attach path (a
`NOT VALID` CHECK validated under a non-blocking lock), so it never blocks the workload on the
default's scan.

### `pgpm.drain_step`

```sql
pgpm.drain_step(
  p_parent       regclass,
  p_batch        int     default null,
  p_include_open boolean default false
) returns text
```

Moves one microbatch of the oldest closed interval's rows out of the `DEFAULT` and into its proper
partition; when that interval empties, it attaches the partition and returns. Returns:

- `'idle'` if there is nothing to drain (or the only remaining interval is still open and
  `p_include_open` is false).
- `'moved:N'` after moving `N` rows but the interval is not yet empty.
- `'attached:<child>:<method>'` when the interval emptied and its partition was attached;
  `method` is `plain`, `check_skip`, or similar.

| Parameter | Meaning |
|---|---|
| `p_batch` | Rows to move this step. Defaults to `config.drain_batch`. If `config.drain_max_blocks` is set, the batch is additionally capped to about that many heap+TOAST blocks (so wide rows cannot make one batch huge). |
| `p_include_open` | When `true`, also drain the current open interval (attaches it via a plain, briefly blocking `ATTACH`). Use only to finish a table. |

The child is created standalone and attached only when the interval empties, so across a multi-step
drain the already-moved rows are not visible through the parent until that attach. A mid-drain read of
the parent undercounts the draining interval; see [`snapshot`](#pgpmsnapshot) and the guide's
[Read consistency during a drain](guide.md#read-consistency-during-a-drain). `drain_all` (one
transaction) and single-batch intervals do not open this gap.

### `pgpm.drain_all`

```sql
pgpm.drain_all(
  p_parent       regclass,
  p_batch        int     default null,
  p_include_open boolean default false
) returns int
```

Calls `drain_step` in a loop until it returns `'idle'`, draining the table to completion in one call.
Returns the number of steps run. Ignores the `paused` flag. With `p_include_open => true` it also
drains and attaches the current open interval (a brief blocking attach against a small default,
cheapest done last). Useful for tests and one-shot conversions; for production prefer the paced
`maintain` cron.

### `pgpm.retain`

```sql
pgpm.retain(p_parent regclass) returns int
```

Drops partitions older than `config.retain` (an interval for `time`/`uuidv7`, a count of
intervals for `id`). Returns the number dropped. Uses plain `DROP` (a brief lock); `null` retain
keeps everything. For very large cold partitions you may prefer to `DETACH ... CONCURRENTLY` by hand.

### `pgpm.set_drain_adaptive`

```sql
pgpm.set_drain_adaptive(p_parent regclass, p_enabled boolean default true) returns void
```

Turns adaptive feathering (DESIGN.md section 8, mode 2) on or off for one table. When on, each
`maintain` tick measures the WAL generation rate and compares it to the rate the checkpointer can
sustain (`max_wal_size / checkpoint_timeout`). If the drain is outrunning a fraction of that
(`drain_wal_high_water`, default 1.0 = the sustainable rate itself) a forced checkpoint and its I/O storm are imminent, so it backs
off *before* the storm (the leading signal); a forced checkpoint that slips through anyway is a reactive
backstop. The budget moves by AIMD (recover up a small step when calm, halve when congested). The
ceiling is `drain_batch` itself (a bigger batch means a bigger WAL spike, so the budget never exceeds
your tuned rate); adaptive only ever feathers *down* from it, as far as `drain_batch`/16 under sustained
pressure. So set `drain_batch` to your optimistic "when there's slack" rate and let the controller back
off automatically under load. Off (the default) keeps the fixed `drain_batch` rate. Toggling resets the
controller state so it restarts cleanly from `drain_batch`. To start a table adaptive from the moment it
is converted, pass [`transmute(..., p_drain_adaptive => true)`](#pgpmtransmute-time-grid-time--uuidv7)
instead of calling this afterward.

### `pgpm.set_drain_ambient`

```sql
pgpm.set_drain_ambient(p_parent regclass, p_factor numeric default 2.0,
                       p_alpha numeric default 0.2, p_floor int default 2) returns void
```

A second, complementary backoff signal makes the drain yield when it is starving the *workload* (which
the WAL-rate signal cannot see -- a crowded-out writer makes little WAL). It counts non-pgpm client
backends stuck on IO/lock waits and is **self-calibrating**: a fixed waiter threshold is the wrong shape
because "normal" is box-dependent, so instead it learns the recent normal as an EWMA baseline and backs
off on a *relative surge* above it. Enable it with:

```sql
select pgpm.set_drain_ambient('public.events', 2.0);  -- factor 2.0; optional alpha, floor args
```

The controller then feathers down when live waiters exceed `drain_ambient_factor` times the learned
`drain_ambient_baseline` (an EWMA, smoothing `drain_ambient_alpha`), floored at `drain_ambient_floor` so
an idle box does not react to a couple of transient waiters. The smoothing is damped 10x during a surge,
so a transient spike stays visible while a sustained regime shift is relearned. `drain_ambient_factor` =
0 (the default) turns the signal off. The old fixed `config.drain_ambient_max_waiters` is still honored as
an optional absolute cap, OR'd on top (0 = off). All three backoff signals (WAL rate, ambient surge,
absolute cap) are OR'd: the drain feathers down if any fires.

## Inspection

### `pgpm.status`

```sql
select * from pgpm.status();
```

One row per managed table.

| Column | Type | Meaning |
|---|---|---|
| `parent` | `regclass` | The managed parent table. |
| `control_kind` | `text` | `time`, `id`, or `uuidv7`. |
| `partition_step` | `text` | The interval or id step. |
| `obtain` | `int` | Partitions kept ahead. |
| `retain` | `text` | Retention policy, or null. |
| `paused` | `boolean` | Whether scheduled maintenance is paused. |
| `n_partitions` | `bigint` | Registered partitions (excludes the DEFAULT). |
| `default_rows` | `bigint` | Rows still in the DEFAULT. |
| `default_oldest` | `text` | Oldest control value still in the DEFAULT. |
| `newest_bound` | `text` | Upper bound of the newest registered partition. |

### `pgpm.check_default`

```sql
pgpm.check_default(p_parent regclass)
  returns table (default_rows bigint, closed_rows bigint, oldest text)
```

The DEFAULT health check. `default_rows` is everything in the DEFAULT (the open interval lives here
normally); `closed_rows` is the alert: rows in already-closed intervals that should have drained.
`closed_rows > 0` in steady state means the drain is behind. `oldest` is the oldest control value
present.

### `pgpm.snapshot`

```sql
pgpm.snapshot(p_rowtype anyelement) returns setof anyelement
```

The read-consistency escape hatch for the [drain visibility gap](guide.md#read-consistency-during-a-drain):
a read-only set-returning function that `UNION`s the parent with every in-flight, not-yet-attached drain
child, so a reader sees the moved rows the parent alone undercounts. Query it inline:

```sql
select count(*) from pgpm.snapshot(null::public.events);
```

You pass the table as a typed-`NULL` anchor, not a `regclass`: a function's row shape is fixed at plan
time and cannot be inferred from a `regclass` *value*, so the anchor carries the rowtype (and `snapshot`
recovers the table from it via `pg_typeof` -> `pg_type.typrelid`). The returned rows are the parent's
type. It is **always fresh** (it rediscovers the in-flight child on every call, so it can neither
double-count an attached child nor miss a new one) and leaves no object behind. Two costs: it is an
**optimization fence** (a dynamic-SQL SRF, so a `WHERE` on top materializes the union before filtering
and will not use the child's `CHECK` exclusion; fine for `COUNT`/full reads, slower than a hand-written
union for heavily-filtered reads on a large table), and it does nothing for writes (an already-moved row
is a silent `0 rows` no-op until it attaches, with no fix). When no drain is in flight it is just
`select * from <parent>`. Raises if the anchor is not a managed table's rowtype.

### `pgpm.check_uuidv7`

```sql
pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
  returns table (sampled bigint, plausible bigint, fraction numeric,
                 oldest timestamptz, newest timestamptz)
```

Samples up to `p_sample` values of a `uuid` column and reports the `fraction` whose embedded
timestamp decodes to a plausible recent time. A low fraction means the column is probably random
(UUIDv4), not time-ordered (UUIDv7/ULID), and is unsafe to partition on. `oldest`/`newest` are the
decoded extremes of the sample. A heuristic, not a proof.

### `pgpm.check_time_monotonic`

```sql
pgpm.check_time_monotonic(p_table regclass, p_id name, p_time name, p_sample int default 1000)
  returns table (sampled bigint, monotonic bigint, fraction numeric)
```

Read-only co-monotonicity check: samples rows ordered by `p_id` and reports the `fraction` for which
`p_time` also rises. A high fraction supports a key-to-time retention bridge (calendar retention on
an id-partitioned table); backfills and out-of-order arrival lower it. The tier-2 safety gate for
that bridge.

## Foreign-key helpers

### `pgpm.restore_incoming_fks`

```sql
pgpm.restore_incoming_fks(p_parent regclass) returns int
```

Re-adds the incoming FKs that `transmute(..., p_incoming_fks => 'preserve')` recorded (the
[`pgpm.dropped_fk`](#pgpmdropped_fk) rows that are currently dropped), pointing them back at the new
partitioned parent with `NOT VALID` + `VALIDATE` (so the re-add is online; a self-referential FK, whose
referencing side is the partitioned parent, is added validating in one step since Postgres rejects
`NOT VALID` there). Returns the number restored. It self-gates on quiescence: a no-op (returns 0) while
the closed tail still has rows or an in-flight child partition exists. The record is kept after
restore, marked live (`restored_at` set), not deleted, so the FK can be suspended again before a later
drain. Safe to call early or repeatedly; `maintain` calls it automatically once the drain is idle,
so you only call it by hand on the synchronous `drain_all` path. See the
[guide](guide.md#incoming-foreign-keys).

### `pgpm.suspend_incoming_fks`

```sql
pgpm.suspend_incoming_fks(p_parent regclass) returns int
```

The inverse of `restore_incoming_fks`, and the other half of the managed-FK invariant *a preserve-managed
FK is live if and only if the closed tail is empty*. When the closed tail has drain work pending, it
re-drops any preserve-managed FK that is currently live (setting `restored_at` back to null) so the
drain never moves referenced rows past a live FK, which a `NO ACTION` FK would block and a
`CASCADE` / `SET NULL` FK would silently honour (deleting or nulling the referencing rows). Returns the
number suspended; a no-op (returns 0) when the closed tail is empty. `maintain` calls it before each
drain step (and `drain_all` at its start); you rarely call it directly.

## Catalog objects

### `pgpm.config`

One row per managed table; the source of truth for its policy. Editable directly, though prefer the
helpers where they exist ([`pgpm.resume`](#pgpmpause--pgpmresume) / [`pgpm.pause`](#pgpmpause--pgpmresume)
for the `paused` flag, [`set_drain_adaptive`](#pgpmset_drain_adaptive) /
[`set_drain_ambient`](#pgpmset_drain_ambient) for the feathering knobs).

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | Managed parent (primary key). |
| `control_column` | `name` | The partition key column. |
| `control_kind` | `text` | `time`, `id`, or `uuidv7`. |
| `partition_step` | `text` | Interval (time/uuidv7) or id step. |
| `partition_anchor` | `text` | Grid origin. |
| `obtain` | `int` | Partitions to keep ahead. |
| `retain` | `text` | Retention policy, or null to keep all. |
| `keep_default` | `boolean` | Keep the DEFAULT safety net. |
| `drain_batch` | `int` | Default rows per drain microbatch. |
| `default_table` | `name` | Name of the DEFAULT partition (`<parent>_default`). |
| `paused` | `boolean` | Whether scheduled maintenance acts on this table. |
| `created_at` | `timestamptz` | When transmuted. |
| `obtain_retry_after` | `timestamptz` | Internal obtain back-off window; null = attempt now. |
| `drain_max_blocks` | `int` | Optional block budget per drain batch; null = cap by `drain_batch` rows only. |
| `drain_adaptive` | `boolean` | Adaptive feathering (mode 2) on/off. Set via `set_drain_adaptive`; default off. |
| `drain_budget` | `int` | Controller state: current adaptive rows/tick budget; null until the first adaptive tick. |
| `drain_wal_high_water` | `numeric` | Back off when the WAL rate exceeds this fraction of the sustainable rate (`max_wal_size`/`checkpoint_timeout`); default 1.0. Lower (e.g. 0.7) is gentler on the workload but drains slower. |
| `drain_ambient_max_waiters` | `int` | Ambient signal, optional absolute cap: also back off when more than this many non-pgpm client backends are stuck on IO/lock waits. 0 = disabled (default). |
| `drain_ambient_factor` | `numeric` | Self-calibrating ambient signal: back off when live waiters exceed this factor times the learned baseline. Set via `set_drain_ambient`; 0 = disabled (default). |
| `drain_ambient_alpha` | `numeric` | EWMA smoothing for the ambient baseline (damped 10x during a surge); default 0.2. |
| `drain_ambient_floor` | `int` | Minimum effective baseline for the ambient surge trigger, so an idle box does not react to a couple of transient waiters; default 2. |
| `drain_ambient_baseline` | `numeric` | Controller state: learned EWMA of the per-tick ambient waiter count; null until the signal is on and the first adaptive tick seeds it. |
| `drain_wal_lsn` | `pg_lsn` | Controller state: previous tick's WAL position (to compute the WAL rate). |
| `drain_wal_at` | `timestamptz` | Controller state: previous tick's timestamp (to compute the WAL rate). |
| `drain_ckpt_seen` | `bigint` | Controller state: last forced-checkpoint counter (reactive backstop); null = uninitialized. |

### `pgpm.part`

Registry of managed partitions (excludes the DEFAULT). `lo`/`hi` are native-grid bounds stored as
text. Columns: `parent_table`, `child_name`, `lo`, `hi`, `created_at`.

### `pgpm.partitions`

A read-friendly view over `pgpm.part`: `parent_table`, `child_name`, `lo`, `hi`, `created_at`,
ordered by parent then `lo`.

### `pgpm.log`

Append-only audit trail of actions. Columns: `id`, `parent_table`, `action` (e.g. `drain_move`,
`drain_attach`, `obtain_skip`), `lo`, `hi`, `method`, `rows`, `at`.

### `pgpm.dropped_fk`

Incoming FKs dropped by `transmute(..., p_incoming_fks => 'preserve')`, kept as managed records so they
can be re-added against the new parent. Columns: `id`, `parent_table`, `referencing_table`,
`constraint_name`, `definition`, `restored_at`, `dropped_at`. `restored_at` tracks lifecycle state
(null = currently dropped/suspended, set = currently live): [`restore_incoming_fks`](#pgpmrestore_incoming_fks)
re-adds the FK and sets it, [`suspend_incoming_fks`](#pgpmsuspend_incoming_fks) re-drops it before a
later drain and clears it. The row persists for the life of the managed FK.
