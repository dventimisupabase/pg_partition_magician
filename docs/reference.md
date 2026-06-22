# pg_partition_magician: reference

Complete reference for the public functions, procedures, and catalog objects in the `pgpm`
schema. For task-oriented walkthroughs, see the [user guide](guide.md); for the design rationale,
see [DESIGN.md](../DESIGN.md).

## Conventions

- Everything lives in the `pgpm` schema.
- `p_parent` is always a `regclass` (the partitioned parent, or the table being adopted). Pass a
  schema-qualified name like `'public.events'`; it is resolved against the current `search_path`.
- "Native" values are a partition kind's internal grid units: `timestamptz` for `time` and
  `uuidv7`, `numeric` for `id`. Partition bounds (`lo`/`hi`) are stored as text in those units.
- The "frontier" is the newest point the table has reached: `now()` for `time`, `max(control)` for
  `id` and `uuidv7`. An interval is "closed" once the frontier has moved past its upper bound; only
  closed intervals are drained.
- Functions raise `pg_partition_magician: ...` (SQLSTATE `P0001`) on misuse.

## Adoption

`adopt` converts an existing, unpartitioned table into a native `RANGE`-partitioned one, online and
metadata-only. It is one function with two type-safe overloads chosen by the width parameter; the
partition kind is read from the control column. pgpm never rewrites the primary key (see
[No PK rewrite](#no-pk-rewrite)).

### `pgpm.adopt` (time grid: time / uuidv7)

```sql
pgpm.adopt(
  p_parent       regclass,
  p_control      name,
  p_interval     interval,
  p_premake      int         default 4,
  p_retention    interval    default null,
  p_keep_default boolean     default true,
  p_drain_batch  int         default 5000,
  p_anchor       timestamptz default '2000-01-01 00:00:00+00',
  p_paused       boolean     default true,
  p_incoming_fks text        default 'error'
) returns regclass
```

The interval overload. The kind is inferred from the control column's type: a `uuid` column is
`uuidv7` (ULID-as-uuid included), a `timestamptz` / `timestamp` / `date` column is `time`. A bare
interval literal is ambiguous against the bigint overload, so cast it: `adopt(t, c, interval '1 month')`.

| Parameter | Meaning |
|---|---|
| `p_parent` | The table to convert: a plain (unpartitioned) table whose primary key already includes `p_control`, or which has no primary key. |
| `p_control` | The column to range-partition on. |
| `p_interval` | Partition width. Whole-month (`interval '1 month'`, `'1 year'`) aligns to the calendar; fixed-duration (`'1 day'`, `'6 hours'`) tiles from `p_anchor`. Mixing month and duration is rejected. For a `uuid` column it is the time width of each partition. |
| `p_premake` | How many partitions to keep created ahead of the frontier. |
| `p_retention` | Drop partitions whose upper bound is older than this interval before the frontier. `null` keeps everything. |
| `p_keep_default` | Keep an (expected-empty) `DEFAULT` partition as a safety net. Leave `true`. |
| `p_drain_batch` | Default rows moved per drain microbatch (see `drain_step`). |
| `p_anchor` | Grid origin for fixed-duration intervals. Calendar-aligned months ignore it. |
| `p_paused` | When `true` (default), register but do not let scheduled `maintenance` act until you unpause. |
| `p_incoming_fks` | `'error'` (default) refuses if other tables have FKs pointing at `p_parent`; `'preserve'` drops each for the conversion, records it, and re-adds it against the new parent once the drain is idle ([`restore_incoming_fks`](#pgpmrestore_incoming_fks)). See [incoming FKs](guide.md#incoming-foreign-keys). |

### `pgpm.adopt` (integer grid: id)

```sql
pgpm.adopt(
  p_parent regclass, p_control name, p_step bigint,
  p_premake int default 4, p_retention bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass
```

The bigint overload, for an integer / `bigint` / `numeric` key (including Snowflake-style ids). An
integer literal selects it with no cast: `adopt(t, c, 10000000)`. Differences from the interval form:

- `p_step` is the partition width in key units (e.g. `10000000` ids per partition).
- `p_retention` is a `bigint` count of intervals to keep, not an interval.
- `p_anchor` is a `bigint` grid origin (default `0`).
- The frontier is `max(control)`.

### What adopt does

Renames the live table to `<name>_default`, creates a partitioned parent under the original name, and
attaches the old table as the `DEFAULT` partition. No rows move. Identity moves to the parent.
Non-unique secondary indexes are carried onto the parent; unique secondary indexes are skipped
(recreate by hand). The adopted table is registered in [`pgpm.config`](#pgpmconfig) and starts paused;
nothing drains until you run `maintenance` / `drain_*` or unpause.

### No PK rewrite

`adopt` never drops or rebuilds the primary key, so the cutover is always metadata-only (no `O(rows)`
index build, ever). It reuses the existing PK in place when `p_control` is already a member of it
(Postgres requires a partitioned PK only to *include* the partition key, not lead it, so a composite
`PK (tenant_id, id)` partitioned by `id` qualifies), and a table with no PK is fine. If the table has
a primary key that does NOT include `p_control` (the classic `events(id PRIMARY KEY, created_at)` that
wants time partitioning), adopt refuses with guidance: make `p_control` part of the primary key first
(a single-column time-ordered key is simplest; or widen the PK yourself via
`CREATE UNIQUE INDEX CONCURRENTLY` then `ALTER TABLE ... ADD PRIMARY KEY USING INDEX`), then re-adopt.

## Maintenance

### `pgpm.maintenance_all`

```sql
call pgpm.maintenance_all()
```

A procedure that runs `maintenance` for every managed table. This is the single entry point you
schedule with `pg_cron`:

```sql
select cron.schedule('pgpm', '1 minute', 'call pgpm.maintenance_all()');
```

### `pgpm.maintenance`

```sql
pgpm.maintenance(p_parent regclass) returns text
```

One maintenance tick for one table: premake, then retention, then a single `drain_step`. Returns a
short text summary. Respects the `paused` flag (returns `'paused'` and does nothing if paused). Each
step runs in its own subtransaction under a short `lock_timeout`, so a step that loses a lock race is
deferred to the next tick rather than aborting the others; premake additionally backs off after a
deferral (tracked in `config.premake_retry_after`).

### `pgpm.premake`

```sql
pgpm.premake(p_parent regclass) returns int
```

Creates partitions ahead of the frontier up to `config.premake`, so live writes always land in a
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
`maintenance` cron.

### `pgpm.retention`

```sql
pgpm.retention(p_parent regclass) returns int
```

Drops partitions older than `config.retention` (an interval for `time`/`uuidv7`, a count of
intervals for `id`). Returns the number dropped. Uses plain `DROP` (a brief lock); `null` retention
keeps everything. For very large cold partitions you may prefer to `DETACH ... CONCURRENTLY` by hand.

### `pgpm.set_drain_adaptive`

```sql
pgpm.set_drain_adaptive(p_parent regclass, p_enabled boolean default true) returns void
```

Turns adaptive feathering (DESIGN.md section 8, mode 2) on or off for one table. When on, each
`maintenance` tick measures the WAL generation rate and compares it to the rate the checkpointer can
sustain (`max_wal_size / checkpoint_timeout`). If the drain is outrunning a fraction of that
(`drain_wal_high_water`, default 1.0 = the sustainable rate itself) a forced checkpoint and its I/O storm are imminent, so it backs
off *before* the storm (the leading signal); a forced checkpoint that slips through anyway is a reactive
backstop. The budget moves by AIMD (recover up a small step when calm, halve when congested). The
ceiling is `drain_batch` itself (a bigger batch means a bigger WAL spike, so the budget never exceeds
your tuned rate); adaptive only ever feathers *down* from it, as far as `drain_batch`/16 under sustained
pressure. So set `drain_batch` to your optimistic "when there's slack" rate and let the controller back
off automatically under load. Off (the default) keeps the fixed `drain_batch` rate. Toggling resets the
controller state so it restarts cleanly from `drain_batch`.

A second, complementary backoff signal is available: set `config.drain_ambient_max_waiters` > 0 and the
controller also feathers down when more than that many non-pgpm client backends are stuck on IO/lock
waits, i.e. the drain is starving the workload (which the WAL-rate signal cannot see -- a crowded-out
writer makes little WAL). The two signals are OR'd. Default 0 (ambient signal off).

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
| `premake` | `int` | Partitions kept ahead. |
| `retention` | `text` | Retention policy, or null. |
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

Re-adds the incoming FKs that `adopt(..., p_incoming_fks => 'preserve')` recorded (the
[`pgpm.dropped_fk`](#pgpmdropped_fk) rows that are currently dropped), pointing them back at the new
partitioned parent with `NOT VALID` + `VALIDATE` (so the re-add is online; a self-referential FK, whose
referencing side is the partitioned parent, is added validating in one step since Postgres rejects
`NOT VALID` there). Returns the number restored. It self-gates on quiescence: a no-op (returns 0) while
the closed tail still has rows or an in-flight child partition exists. The record is kept after
restore, marked live (`restored_at` set), not deleted, so the FK can be suspended again before a later
drain. Safe to call early or repeatedly; `maintenance` calls it automatically once the drain is idle,
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
number suspended; a no-op (returns 0) when the closed tail is empty. `maintenance` calls it before each
drain step (and `drain_all` at its start); you rarely call it directly.

## Catalog objects

### `pgpm.config`

One row per managed table; the source of truth for its policy. Editable (e.g.
`update pgpm.config set paused = false where parent_table = 'public.events'::regclass;`).

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | Managed parent (primary key). |
| `control_column` | `name` | The partition key column. |
| `control_kind` | `text` | `time`, `id`, or `uuidv7`. |
| `partition_step` | `text` | Interval (time/uuidv7) or id step. |
| `partition_anchor` | `text` | Grid origin. |
| `premake` | `int` | Partitions to keep ahead. |
| `retention` | `text` | Retention policy, or null to keep all. |
| `keep_default` | `boolean` | Keep the DEFAULT safety net. |
| `drain_batch` | `int` | Default rows per drain microbatch. |
| `default_table` | `name` | Name of the DEFAULT partition (`<parent>_default`). |
| `paused` | `boolean` | Whether scheduled maintenance acts on this table. |
| `created_at` | `timestamptz` | When adopted. |
| `premake_retry_after` | `timestamptz` | Internal premake back-off window; null = attempt now. |
| `drain_max_blocks` | `int` | Optional block budget per drain batch; null = cap by `drain_batch` rows only. |
| `drain_adaptive` | `boolean` | Adaptive feathering (mode 2) on/off. Set via `set_drain_adaptive`; default off. |
| `drain_budget` | `int` | Controller state: current adaptive rows/tick budget; null until the first adaptive tick. |
| `drain_wal_high_water` | `numeric` | Back off when the WAL rate exceeds this fraction of the sustainable rate (`max_wal_size`/`checkpoint_timeout`); default 1.0. Lower (e.g. 0.7) is gentler on the workload but drains slower. |
| `drain_ambient_max_waiters` | `int` | Ambient-contention signal: also back off when more than this many non-pgpm client backends are stuck on IO/lock waits (the drain is starving the workload). 0 = disabled (default). |
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
`drain_attach`, `premake_skip`), `lo`, `hi`, `method`, `rows`, `at`.

### `pgpm.dropped_fk`

Incoming FKs dropped by `adopt(..., p_incoming_fks => 'preserve')`, kept as managed records so they
can be re-added against the new parent. Columns: `id`, `parent_table`, `referencing_table`,
`constraint_name`, `definition`, `restored_at`, `dropped_at`. `restored_at` tracks lifecycle state
(null = currently dropped/suspended, set = currently live): [`restore_incoming_fks`](#pgpmrestore_incoming_fks)
re-adds the FK and sets it, [`suspend_incoming_fks`](#pgpmsuspend_incoming_fks) re-drops it before a
later drain and clears it. The row persists for the life of the managed FK.
