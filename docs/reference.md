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

These convert an existing, unpartitioned table into a native `RANGE`-partitioned one, online. They
differ only in the partition kind and therefore in the step/retention/anchor types; all other
parameters are identical.

### `pgpm.adopt` (time)

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

Adopts `p_control` (a `timestamptz` / `timestamp` / `date` column) on an interval grid. Returns the
parent's `regclass`.

| Parameter | Meaning |
|---|---|
| `p_parent` | The table to convert. Must currently be a plain (unpartitioned) table. |
| `p_control` | The column to range-partition on. |
| `p_interval` | Partition width. Whole-month (`'1 month'`, `'1 year'`) aligns to the calendar; fixed-duration (`'1 day'`, `'6 hours'`) tiles from `p_anchor`. Mixing month and duration is rejected. |
| `p_premake` | How many partitions to keep created ahead of the frontier. |
| `p_retention` | Drop partitions whose upper bound is older than this interval before `now()`. `null` keeps everything. |
| `p_keep_default` | Keep an (expected-empty) `DEFAULT` partition as a safety net. Leave `true`. |
| `p_drain_batch` | Default rows moved per drain microbatch (see `drain_step`). |
| `p_anchor` | Grid origin for fixed-duration intervals. Calendar-aligned months ignore it. |
| `p_paused` | When `true` (default), register but do not let scheduled `maintenance` act until you unpause. |
| `p_incoming_fks` | How to handle FKs that other tables have pointing at `p_parent`. `'error'` (default) refuses; `'drop'` drops and records them for composite-FK rebuild (`generate_fk_recovery`); `'preserve'` records and drops them but marks them for verbatim restoration against the new parent (`restore_incoming_fks`), valid only when every incoming FK is happy-path eligible (its referenced columns equal the parent's surviving unique key). See [incoming FKs](guide.md#incoming-foreign-keys). |

What it does: renames the live table to `<name>_default`, creates a partitioned parent under the
original name, and attaches the old table as the `DEFAULT` partition. No rows move. The primary key
widens to `(control, id)`; if a matching unique index was pre-built with
[`build_pk_concurrently`](#pgpmbuild_pk_concurrently), adopt promotes it (metadata-only cutover),
otherwise it builds the index in-transaction under `ACCESS EXCLUSIVE` (`O(rows)`, fine for small
tables only). Non-unique secondary indexes are carried onto the parent; unique secondary indexes are
skipped (recreate by hand). Identity moves to the parent.

The adopted table is registered in [`pgpm.config`](#pgpmconfig) and starts paused; nothing is
drained until you run `maintenance`/`drain_*` or unpause.

### `pgpm.adopt_by_id` (id)

```sql
pgpm.adopt_by_id(
  p_parent regclass, p_control name, p_step bigint,
  p_premake int default 4, p_retention bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass
```

Same as `adopt`, for an integer/`bigint`/`numeric` key (including Snowflake-style ids). Differences:

- `p_step` (`bigint`) is the partition width in key units, e.g. `10000000` ids per partition.
- `p_retention` is a `bigint` count of intervals to keep, not an interval.
- `p_anchor` is a `bigint` grid origin (default `0`).
- The frontier is `max(control)`.

When the id key is already the table's single-column PK, the partition key covers it, so adopt
reuses the existing PK index in place rather than rebuilding it.

### `pgpm.adopt_by_uuidv7` (uuidv7 / ULID)

```sql
pgpm.adopt_by_uuidv7(
  p_parent regclass, p_control name, p_interval interval,
  p_premake int default 4, p_retention interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass
```

Same as `adopt`, for a `uuid` column holding time-ordered UUIDv7 (or ULID-as-uuid) values. Uses a
time grid; bounds are encoded as uuids via a pure-SQL `uuid <-> ms` codec. The column type cannot
prove the values are time-ordered, so adopt samples them and raises a `notice` if they look random
(likely UUIDv4); see [`check_uuidv7`](#pgpmcheck_uuidv7).

### `pgpm.build_pk_concurrently`

```sql
call pgpm.build_pk_concurrently(
  p_parent  regclass,
  p_control name,
  p_timeout interval default '6 hours',
  p_poll    interval default '5 seconds'
)
```

A procedure (call it, do not `select` it). Builds the default's composite PK index online, before
`adopt`, so the cutover stays metadata-only even on a very large table. `CREATE INDEX CONCURRENTLY`
cannot run inside a function, so this schedules the CIC on a `pg_cron` worker, polls until the index
is valid (up to `p_timeout`, every `p_poll`), then unschedules. Run it first, then `adopt`; adopt
detects the ready index and promotes it.

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

Re-adds the incoming FKs that `adopt(..., p_incoming_fks => 'preserve')` recorded (the `restorable`
rows of [`pgpm.dropped_fk`](#pgpmdropped_fk)), pointing them back at the new partitioned parent with
`NOT VALID` + `VALIDATE` (so the re-add is online). Returns the number restored. It self-gates on
quiescence: a no-op (returns 0) while the closed tail still has rows or an in-flight child partition
exists, because the drain moves rows through an unattached child that a `NO ACTION` FK would reject.
Safe to call early or repeatedly; `maintenance` calls it automatically once the drain is idle, so you
only call it by hand on the synchronous `drain_all` path. See the
[guide](guide.md#incoming-foreign-keys).

### `pgpm.generate_fk_recovery`

```sql
pgpm.generate_fk_recovery(p_parent regclass)
  returns table (referencing_table regclass, sql text)
```

For each incoming FK that `adopt(..., p_incoming_fks => 'drop')` recorded in
[`pgpm.dropped_fk`](#pgpmdropped_fk), emits a ready-to-review script that denormalizes the partition
key onto the referencing table and rebuilds the FK as a composite FK (`NOT VALID` + `VALIDATE`, to
avoid a long lock). Generated, not executed: review it (the companion column name is a suggestion;
batch the backfill for large tables) before running. See the
[incoming FKs guide](guide.md#incoming-foreign-keys).

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

Incoming FKs dropped by `adopt(..., p_incoming_fks => 'drop' | 'preserve')`, kept for
reconstruction. Columns: `id`, `parent_table`, `referencing_table`, `constraint_name`, `definition`,
`referencing_columns`, `referenced_columns`, `restorable`, `dropped_at`. When `restorable` is true
(the `'preserve'` mode), the FK is re-added verbatim against the parent by
[`restore_incoming_fks`](#pgpmrestore_incoming_fks) and that row is consumed; when false (the
`'drop'` mode), feed it to [`generate_fk_recovery`](#pgpmgenerate_fk_recovery) for the composite
rebuild.
