# Changelog

## [Unreleased]

- `adopt(..., p_incoming_fks => 'preserve')` + `pgpm.restore_incoming_fks(parent)`: preserve incoming
  foreign keys on the id/uuidv7 happy path. When the partition key already is the referenced
  single-column PK, the partitioned parent keeps that unique key, so an incoming FK need not be
  denormalized into a composite FK (unlike the widening time case). The drain moves rows through an
  unattached child, which a live `NO ACTION` FK would reject, so `'preserve'` records and drops each
  eligible incoming FK at adopt, and `restore_incoming_fks` re-adds it verbatim against the new parent
  (`NOT VALID` + `VALIDATE`) once the drain is quiescent. `maintenance` calls the restore
  automatically; the synchronous `drain_all` path calls it by hand. `'preserve'` refuses the widening
  case (use `'drop'` + `generate_fk_recovery`). New `pgpm.dropped_fk.restorable` column distinguishes
  the two. Referential actions (`CASCADE` / `SET NULL` / `RESTRICT`), `DEFERRABLE`-ness, and
  self-referential FKs are preserved (the self-referential re-add is validating, not online, since
  Postgres rejects a `NOT VALID` FK on a partitioned referencing table). The lifecycle is managed: a
  preserve-managed FK is live only while the closed tail is empty. `pgpm.suspend_incoming_fks` re-drops
  a live managed FK before a drain that would move referenced rows, and `maintenance` (and `drain_all`)
  call it so a later premake-miss catch-up drain neither stalls (`NO ACTION`) nor silently
  deletes/nulls the referencing rows (`CASCADE` / `SET NULL`). New `pgpm.dropped_fk.restored_at` tracks
  the live/dropped state. (tests/19-24)
- `build_pk_concurrently(parent, control)`: a procedure that builds the default's
  composite PK index ONLINE before `adopt`, so the cutover stays metadata-only even on
  very large tables (at ~300M rows the previous in-transaction build was a ~28-minute
  write-blocking window). `CREATE INDEX CONCURRENTLY` can't run inside a function, but it
  can from a pg_cron worker, so this schedules the CIC as a cron job, polls until the
  index is valid, then unschedules. Entirely inside pgpm (no DDL handed to the operator),
  using the existing pg_cron dependency. `adopt` then detects the pre-built index by its
  columns and promotes it; it falls back to the in-transaction build when none exists.
- `adopt` no longer runs `premake` inside its transaction. Attaching a partition to a
  parent whose DEFAULT already holds data makes Postgres scan the default, and inside
  adopt's `ACCESS EXCLUSIVE` transaction that scan blocked all access for its duration
  (~minutes per premade partition at scale). `adopt` now does the metadata-only cutover
  only (a fresh parent with just the DEFAULT attached scans nothing), so it stays online
  even on a 100GB+ table. Run `pgpm.premake()` / `pgpm.maintenance()` afterward to build
  the future partitions online (their `VALIDATE` scans run under a non-blocking lock).
  Until then, writes route to the DEFAULT (correct, just not yet split into future cells).
- `maintenance` no longer lets a premake/retention failure abort the drain. Premaking a
  future partition needs `ACCESS EXCLUSIVE` on the parent plus a scan of the DEFAULT, which
  contends with concurrent inserts into the default's open cell; under sustained write load
  the two sides could deadlock, and because premake ran first in the same transaction the
  deadlock aborted the whole maintenance run, so the drain never made progress. `maintenance`
  now caps lock waits (`lock_timeout`, turning a would-be deadlock into a fast retryable miss)
  and isolates premake, retention, and the drain in separate subtransactions: a step that
  loses the lock race is deferred (logged as `*_skip`, retried next tick) without aborting the
  drain. The closed-tail drain attaches via the scan-skip path, so it keeps converting the
  table online even while premake repeatedly defers under load. Two further safeguards keep
  premake from disrupting the workload under sustained writes: (a) premake/retention use a very
  short `lock_timeout` so a lost lock race fails in milliseconds -- barely blocking the workload,
  and bailing before premake's `VALIDATE` scan of the default; (b) after a deferral, premake
  backs off (a window recorded in `pgpm.config.premake_retry_after`) instead of retrying every
  tick. The drain keeps a longer `lock_timeout` so its infrequent, must-win attach isn't starved.
- `drain_step`'s "any rows left in this range?" check now uses `EXISTS` instead of `count(*)`.
  The old `count(*)` re-scanned the entire remaining range after every microbatch -- O(rows^2 /
  batch) work, and while the default is not all-visible mid-drain the planner seq-scans the
  range each step (a sequential-scan storm that dominates I/O at scale). `EXISTS` stops at the
  first row (index scan), which is all the drain needs to decide between draining and attaching.
- `adopt` no longer scans the table to advance identity sequences. After the cutover it advances
  each identity sequence past the largest existing value -- but adopt has just swapped the PK to
  `(control, id)`, leaving no id-leading index, so the old `select max(id)` seq-scanned the whole
  DEFAULT under adopt's `ACCESS EXCLUSIVE` lock: O(rows), a multi-minute blocking step at 100GB+
  scale that undercut the metadata-only cutover. `adopt` now captures `max(identity)` up front --
  while the table's original id index still exists, so it is an index lookup -- and reuses it to
  advance the (freshly recreated) parent sequence. The cutover stays metadata-only at any size.
- `adopt` reuses the existing PK when the partition key already covers it. For `id` / `uuidv7`
  tables the computed PK columns equal the existing PK, so adopt no longer drops and rebuilds an
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
- `adopt` now refuses up front when an orphaned child-partition table exists. A drain creates each
  child as a standalone table (`CREATE TABLE ... LIKE`) and ATTACHes it only at the end of that
  child's drain, so an interrupted drain leaves an un-attached child -- which `DROP TABLE <parent>
  CASCADE` does not remove (no dependency on the parent). Re-adopting the recreated table would let
  the next drain reuse the orphan by name and collide on its stale keys, surfacing as a cryptic
  mid-drain "duplicate key" deep inside `drain_step`. `adopt` now detects any standalone
  (un-attached) table whose name matches this parent's child-partition naming and raises a clear,
  actionable error instead. (tests/18)

## [0.1.0] - 2026-06-19

Initial release of pg_partition_magician.

- Pure-SQL online RANGE-partition manager (schema `pgpm`); only runtime dependency is pg_cron.
- Partition dimensions: `time`, `id` (bigint/numeric, incl. Snowflake-style), `uuidv7`/ULID-as-uuid. float/double rejected.
- `adopt` / `adopt_by_id` / `adopt_by_uuidv7`: online conversion of an existing table (attach as DEFAULT, no rebuild of the default's PK index).
- premake ahead of the write frontier; paced microbatch drain of the DEFAULT's closed tail (scan-skip attach); retention; maintenance via pg_cron.
- Incoming-FK handling: refuse by default, opt-in drop+record, and `generate_fk_recovery()`.
- Three install channels (psql / bundle / dbdev-TLE) built from one source; PG 15-18 channel test matrix; 53 pgTAP tests.
