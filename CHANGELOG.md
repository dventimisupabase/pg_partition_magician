# Changelog

## [Unreleased]

- **The `transmute` redesign: one function, metadata-only, never rewrites the primary key.** The three
  entry points (`transmute` / `transmute_by_id` / `transmute_by_uuidv7`) collapse into a single overloaded `transmute`:
  a `bigint` width selects the integer grid, an `interval` width the time grid, with `time` vs `uuidv7`
  inferred from the control column's type. Bare interval literals must cast: `transmute(t, c, interval '1
  month')`. `transmute` no longer drops or rebuilds the primary key, so the cutover is always metadata-only:
  it reuses the existing PK when the control column is a member of it (Postgres requires only that a
  partitioned PK include the partition key, not lead it, so `PK (tenant_id, id)` partitioned by `id`
  qualifies), and refuses (with a suggested migration) a table whose primary key excludes the control
  column, or that has no primary key at all (pgpm does not support no-PK tables), betting on a
  time-ordered primary key (Snowflake bigint / UUIDv7 / ULID) as the data model. Forbidding PK rewrites removed `build_pk_concurrently`, the composite-FK recovery
  path (`generate_fk_recovery`, the `'drop'` incoming-FK mode, the `dropped_fk` composite columns), and
  the build-path complexity; every incoming FK is now the `preserve` path. (tests/25)
- **Retention reclaims the un-drained `DEFAULT` tail (issue #91).** When the drain lags, an interval
  that ages past `retain` while still in the `DEFAULT` is now reclaimed in place: the drain `DELETE`s it
  straight out of the `DEFAULT` (paced like a microbatch, logged as `retain_reclaim`) instead of
  materializing a partition that `retain` would immediately drop. Retention now bounds storage even on a
  never-completing drain, and the materialize-then-drop churn is gone. `retain()` itself is unchanged (a
  cheap `DROP` of materialized partitions). (tests/34)
- **`status()` distinguishes a wedged drain from a slow one (issue #92).** It gains `closed_rows` (the
  drainable backlog, the same value `check_default` reports), `last_drained` (when the drain last made
  progress), and `drain_skips` (deferrals logged since that progress). A non-zero `closed_rows` with a
  stale `last_drained` and a climbing `drain_skips` is a wedged drain (e.g. the upsert/duplicate-key
  wedge); a healthy slow drain shows `closed_rows` falling and `drain_skips` near zero. (tests/35)
- **transmute refuses a random-uuid control column (issue #96).** A `uuid` control column is treated as
  `uuidv7` on assumption; when it samples as overwhelmingly random (UUIDv4 -- a plausibility fraction
  below 0.5), transmute now refuses rather than only warning, since range-partitioning a
  non-time-ordered key scatters rows across meaningless partitions on a garbage frontier (mirroring the
  float-key and PK refusals). A new `p_force_uuidv7 => true` overrides it for an operator certain the
  column is time-ordered. (tests/13, tests/39)
- **The block budget no longer disables itself when row stats are missing (issue #93).**
  `drain_max_blocks` translates to a row cap via the default's average bytes/row. When `reltuples <= 0`
  (a freshly transmuted or never-analyzed default -- the early-drain window when it is largest and
  widest) the budget previously fell back to the raw `drain_batch` row count, so a batch of wide
  incompressible rows could be the multi-GB spike the feature exists to prevent. It now estimates the
  average by sampling `pg_column_size` (cheap and TOAST-aware), so the budget holds even before ANALYZE.
  (tests/36)
- **The adaptive ambient signal no longer depends on `pg_monitor` (issue #98); pg_cron is again the only
  runtime dependency.** The consumer-priority signal previously read `pg_stat_activity.wait_event`, which
  Postgres masks for other roles unless the reader holds `pg_monitor`. It is rebuilt from two
  role-independent terms, OR'd, on catalogs any unprivileged role reads in full: a **lock-wait** count
  from `pg_locks` (non-pgpm backends blocked on an ungranted lock) and a **read-I/O latency** from
  `pg_stat_database` (ms/block, inert when `track_io_timing` is off). Both are self-calibrating (EWMA
  baseline + relative surge) like before; the `drain_ambient_*` knobs are unchanged, with new controller
  state `drain_ambient_io_baseline` / `drain_io_read_time` / `drain_io_blks_read`. `_ambient_io_waiters()`
  is replaced by `_ambient_lock_waiters()`. (tests/26, tests/41)
- **A non-PK UNIQUE secondary index is no longer silently dropped (issue #90).** transmute now carries
  it onto the parent as a partitioned unique index when its key includes the partition key (global
  uniqueness genuinely preserved, exactly as the PK is reused), and refuses with guidance when it
  excludes the partition key, or is partial/expression (global uniqueness cannot be enforced on a
  partitioned table) -- the same refuse-or-preserve contract as the PK and incoming-FK cases, instead of
  a `raise notice` that quietly lost the guarantee. (tests/33)
- **An in-flight (unattached) drain child is now tracked in pgpm's catalog (issue #94).** The drain
  creates each child standalone and attaches it only when the interval has fully moved; that child is
  now recorded in `pgpm.part` with a new `attached` column set `false` at creation and flipped `true` at
  the attach, instead of being discoverable only by scanning `pg_class`. `status()` gains
  `inflight_partitions` (and `n_partitions` now counts only attached partitions); `pgpm.partitions`
  exposes `attached`; `retain` only drops attached partitions, never an in-flight one. (tests/37)
- **A preserve-managed incoming FK can no longer be permanently bricked by an orphan, and its state is
  visible (issue #95).** `restore_incoming_fks` now splits the re-add: `ADD CONSTRAINT ... NOT VALID`
  (enforces every new write, always succeeds) is committed separately from `VALIDATE`. An orphan written
  while the FK is suspended (RI is off for the drain's duration -- inherent) used to make `VALIDATE` fail
  and roll the whole re-add back, so the FK was never restored, silently. Now the FK comes back enforcing
  new writes immediately and a blocked `VALIDATE` leaves it `NOT VALID`, surfaced by the new
  `status().fks_unvalidated`. New `pgpm.incoming_fk_orphans(parent)` lists the blocking rows and
  `pgpm.validate_incoming_fks(parent)` finishes validation once they are cleared; `status().fks_suspended`
  surfaces the RI-off window. `pgpm.dropped_fk` gains a `validated_at` column. (tests/38)
- `transmute(..., p_incoming_fks => 'preserve')` + `pgpm.restore_incoming_fks` / `pgpm.suspend_incoming_fks`:
  keep incoming foreign keys across the conversion. Since `transmute` never rewrites the PK, the referenced
  unique key always survives, so `'preserve'` drops each incoming FK for the conversion, records it in
  `pgpm.dropped_fk`, and re-adds it verbatim against the new parent (`NOT VALID` + `VALIDATE`) once the
  drain is idle. `maintain` manages the lifecycle: a managed FK is live only while the closed tail is
  empty, so it suspends (re-drops) a live FK before a drain that would move referenced rows and restores
  it after, and a later obtain-miss drain neither stalls (`NO ACTION`) nor silently deletes/nulls the
  referencing rows (`CASCADE` / `SET NULL`). Referential actions, `DEFERRABLE`-ness, and self-referential
  FKs are preserved (the self-ref re-add is validating, not online). `pgpm.dropped_fk.restored_at` tracks
  the live/dropped state. (tests/19-24)
- `transmute` no longer runs `obtain` inside its transaction. Attaching a partition to a
  parent whose DEFAULT already holds data makes Postgres scan the default, and inside
  transmute's `ACCESS EXCLUSIVE` transaction that scan blocked all access for its duration
  (~minutes per premade partition at scale). `transmute` now does the metadata-only cutover
  only (a fresh parent with just the DEFAULT attached scans nothing), so it stays online
  even on a 100GB+ table. Run `pgpm.obtain()` / `pgpm.maintain()` afterward to build
  the future partitions online (their `VALIDATE` scans run under a non-blocking lock).
  Until then, writes route to the DEFAULT (correct, just not yet split into future cells).
- `maintain` no longer lets an obtain/retain failure abort the drain. Obtaining a
  future partition needs `ACCESS EXCLUSIVE` on the parent plus a scan of the DEFAULT, which
  contends with concurrent inserts into the default's open cell; under sustained write load
  the two sides could deadlock, and because obtain ran first in the same transaction the
  deadlock aborted the whole maintenance run, so the drain never made progress. `maintain`
  now caps lock waits (`lock_timeout`, turning a would-be deadlock into a fast retryable miss)
  and isolates obtain, retain, and the drain in separate subtransactions: a step that
  loses the lock race is deferred (logged as `*_skip`, retried next tick) without aborting the
  drain. The closed-tail drain attaches via the scan-skip path, so it keeps converting the
  table online even while obtain repeatedly defers under load. Two further safeguards keep
  obtain from disrupting the workload under sustained writes: (a) obtain/retain use a very
  short `lock_timeout` so a lost lock race fails in milliseconds -- barely blocking the workload,
  and bailing before obtain's `VALIDATE` scan of the default; (b) after a deferral, obtain
  backs off (a window recorded in `pgpm.config.obtain_retry_after`) instead of retrying every
  tick. The drain keeps a longer `lock_timeout` so its infrequent, must-win attach isn't starved.
- `drain_step`'s "any rows left in this range?" check now uses `EXISTS` instead of `count(*)`.
  The old `count(*)` re-scanned the entire remaining range after every microbatch -- O(rows^2 /
  batch) work, and while the default is not all-visible mid-drain the planner seq-scans the
  range each step (a sequential-scan storm that dominates I/O at scale). `EXISTS` stops at the
  first row (index scan), which is all the drain needs to decide between draining and attaching.
- `transmute` no longer scans the table to advance identity sequences. After the cutover it advances
  each identity sequence past the largest existing value -- but transmute has just swapped the PK to
  `(control, id)`, leaving no id-leading index, so the old `select max(id)` seq-scanned the whole
  DEFAULT under transmute's `ACCESS EXCLUSIVE` lock: O(rows), a multi-minute blocking step at 100GB+
  scale that undercut the metadata-only cutover. `transmute` now captures `max(identity)` up front --
  while the table's original id index still exists, so it is an index lookup -- and reuses it to
  advance the (freshly recreated) parent sequence. The cutover stays metadata-only at any size.
- `transmute` reuses the existing PK when the partition key already covers it. For `id` / `uuidv7`
  tables the computed PK columns equal the existing PK, so transmute no longer drops and rebuilds an
  identical index -- it reuses the index in place. In the common case the one-time setup cost center
  collapses to zero and only the drain remains. Flat (single-digit ms) to ~40M rows. (tests/15)
- `drain_max_blocks` config: block-budgeted drain batching. Batching by a fixed row count is unsafe
  when row width varies (20 000 rows each carrying a 2 MB document is tens of GB rewritten in one
  microbatch). When set, `drain_step` caps each microbatch at roughly that many heap+TOAST blocks
  (translated to a row limit via the default's average bytes/row) and takes the smaller of that and
  `drain_batch`; when null it falls back to the row cap unchanged. (tests/17)
- `pgpm.check_time_monotonic(parent, key_col, time_col)`: an additive, read-only co-monotonicity
  check, the tier-2 safety gate for a future key-to-time retention bridge (calendar retention on an
  id-partitioned table). It samples whether the id and timestamp rise together and reports the
  fraction in order, analogous to `check_uuidv7`'s plausibility sampling. (tests/16)
- `transmute` now refuses up front when an orphaned child-partition table exists. A drain creates each
  child as a standalone table (`CREATE TABLE ... LIKE`) and ATTACHes it only at the end of that
  child's drain, so an interrupted drain leaves an un-attached child -- which `DROP TABLE <parent>
  CASCADE` does not remove (no dependency on the parent). Re-transmuting the recreated table would let
  the next drain reuse the orphan by name and collide on its stale keys, surfacing as a cryptic
  mid-drain "duplicate key" deep inside `drain_step`. `transmute` now detects any standalone
  (un-attached) table whose name matches this parent's child-partition naming and raises a clear,
  actionable error instead. (tests/18)

## [0.1.0] - 2026-06-19

Initial release of pg_partition_magician.

- Pure-SQL online RANGE-partition manager (schema `pgpm`); only runtime dependency is pg_cron.
- Partition dimensions: `time`, `id` (bigint/numeric, incl. Snowflake-style), `uuidv7`/ULID-as-uuid. float/double rejected.
- `transmute` / `transmute_by_id` / `transmute_by_uuidv7`: online conversion of an existing table (attach as DEFAULT, no rebuild of the default's PK index).
- obtain ahead of the write frontier; paced microbatch drain of the DEFAULT's closed tail (scan-skip attach); retain; maintenance via pg_cron.
- Incoming-FK handling: refuse by default, opt-in drop+record, and `generate_fk_recovery()`.
- Three install channels (psql / bundle / dbdev-TLE) built from one source; PG 15-18 channel test matrix; 53 pgTAP tests.
