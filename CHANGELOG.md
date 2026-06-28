# Changelog

## [Unreleased]

- **`from_hypertable` pre-drains the append-only catch-up online too (default, non-tracking path).** Without
  `p_track_changes`, the cutover caught up every row appended past the copy watermark in one `insert ...
  where control > watermark` *under the lock*, so that window grew with the copy -- the same wound #170
  closed for the tracking path, still open for the default. New `from_hypertable_drain_appends` (a `_step` +
  driver, mirroring the #170 delta drain) copies that tail **online, in bounded batches that advance the
  watermark**, so the locked catch-up applies only the final tail. It is purely additive (append-only means
  copied rows never change), so unlike the delta drain it needs no delta, no reconcile, no key, and no dest
  index, and works on a **keyless** hypertable (the common shape); each batch is bounded to the control
  value `p_batch` rows past the watermark and **inclusive of ties** at that bound (so no tie straddling a
  batch boundary is dropped), as literal constants for chunk exclusion. The cutover runs it automatically
  (`p_predrain`, default `true`) for the non-tracking path, and the watermark read that drives the under-lock
  catch-up now happens **before** the lock, so an `O(rows)` `max()` seqscan on a keyless dest is no longer in
  the blocking window. (issue #174; tests/timescale/db/15)
- **`from_hypertable` drains the change-capture delta online, before the cutover lock.** With
  `p_track_changes`, the cutover reconciled the *entire* delta under the `ACCESS EXCLUSIVE` lock -- and the
  delta is every key touched for the whole online-copy duration, so the locked window grew with the table it
  is meant to migrate quickly. New `from_hypertable_drain_delta` (a `_step` + driver pair, mirroring
  `drain`) reconciles the delta **online, in bounded micro-batches, while the source stays live**, chasing
  the backlog down so the lock applies only a tiny residual. The reconcile is idempotent and
  order-independent per key, which makes incremental draining safe; it delete-RETURNS each batch from the
  delta as the authority and reconciles exactly those keys against the live source (so a change is never
  deleted-without-applying), bounded per batch to the touched control range for chunk exclusion. The cutover
  now runs this pre-drain automatically (best-effort, new `p_predrain` default `true`); under sustained write
  load it stops at a residual threshold and the under-lock pass -- still the correctness backstop -- finishes
  the rest, or a convergence budget fails loudly. The delta gains a monotonic `pgpm_seq` ordering column for
  the batch watermark. Also closes a pre-existing silent-loss hole: tracking is now refused on a key with a
  nullable (non-control) column, since a `NULL` key component can never be reconciled. (issue #170,
  supersedes #165; tests/timescale/db/14)
- **`transmute` and `untransmute` preserve an identity sequence's exact position.** Both reseeded the
  identity sequence to `max(id) + 1`, which is correct only when the sequence sits at its max. A sequence
  **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted high rows -- would then
  re-issue ids it had already handed out. Both now capture the original sequence's next value up front and
  seed to the greater of `max(id) + 1` and that value, so a transmute (and a transmute/untransmute round
  trip) never moves the sequence backward over ids already issued. The common case (a sequence at its max)
  is unchanged. (This generalises the `from_hypertable`-specific preservation to plain `transmute`.)
  (tests/56)
- **`from_hypertable` warns about transient disk use up front.** The online copy writes a full second table
  before cutover, so the migration transiently needs roughly the source's current size in extra disk
  (reclaimed when the old hypertable is dropped at cutover). `from_hypertable_preflight` now raises a
  `NOTICE` with that estimate, and a new `from_hypertable_disk_estimate(p_hypertable)` returns it as `bigint`
  (the total on-disk size across all chunks) so a volume can be sized ahead of time. (tests/timescale/db/12)
- **`from_hypertable` preserves the source identity sequence's exact position.** `transmute` seeds a
  migrated identity sequence to `max(id) + 1`, which is correct only when the sequence sits right at its
  max. A sequence that is **ahead** of `max(id)` -- from rolled-back inserts, sequence caching, or deleted
  high rows -- would then re-issue ids the source had already moved past. `from_hypertable` now captures each
  source sequence's next value before the cutover and advances the migrated sequence to it (when higher)
  after the transmute handoff, so the next generated id continues from where the source left off. (Plain
  `transmute` of a non-hypertable still seeds to `max(id) + 1`; this preservation is specific to the
  `from_hypertable` path, which discards the source sequence object during the copy.) (tests/timescale/db/11)
- **`from_hypertable` can migrate update/delete workloads online (trigger-based change capture).** The
  default cutover catch-up is append-only (rows past the copy watermark), which silently loses UPDATEs and
  DELETEs to already-copied rows that arrive during the online window. Pass `p_track_changes => true` and
  `from_hypertable_copy` installs an `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values to a `<rel>_pgpm_delta` table; the cutover reconciles every touched key against the
  live source (delete each dirty key's copied row, then re-insert its current source row, which is
  idempotent and order-independent and covers inserts, updates, and deletes). The cutover auto-detects the
  apparatus, so the two phases cannot disagree, and cleans it up inside the swap transaction. Reconciliation
  is by the key `transmute` reuses (a primary key or unique constraint), so tracking is refused up front on
  a keyless table rather than silently falling back. Default stays `false` (append-only, no trigger
  overhead). (tests/timescale/db/10)
- **CHECK constraints reach the partitioned parent (bug fix).** `transmute` built the parent with `LIKE`
  but without `INCLUDING CONSTRAINTS`, so the user's CHECK constraints stayed on the monolith child only --
  the parent, the DEFAULT, and future forward partitions did not enforce them (a silent gap: new rows in
  new partitions escaped the CHECK). The parent is now built `INCLUDING CONSTRAINTS`; the transient
  `pgpm_monolith_bound` CHECK that `LIKE` also copies is dropped from the parent (the monolith keeps its
  own copy for the metadata-only attach). CHECK constraints now propagate to every partition. (tests/55;
  tests/timescale/db/07)
- **Generated columns are supported (bug fix).** `drain`, `refine`, and `from_hypertable` move rows by
  building an explicit column list, which wrongly **included generated columns** -- so the move failed
  with `cannot insert a non-DEFAULT value into a generated column`. Two fixes: omit generated columns from
  those INSERT lists (they recompute on insert), and create the destination/partition child with
  `INCLUDING GENERATED` so its generated column matches the parent (otherwise the attach failed with
  `column ... must be a generated column`). A table with a STORED generated column now drains, refines, and
  migrates correctly, with the generated value recomputed on the destination. (tests/54;
  tests/timescale/db/09)
- **`from_hypertable` hardening tests.** Added retention translation (a `drop_chunks` policy becomes pgpm
  `retain`), schema fidelity (the parent carries the primary key including the control column, secondary
  indexes, column defaults, and NOT NULL), and abort/rollback (nothing is irreversible before cutover; a
  failure inside the cutover transaction rolls back whole and leaves the source intact) -- run across both
  fleet TimescaleDB versions. (tests/timescale/db/06-08)

- **The `from_hypertable` CI track runs against the fleet's TimescaleDB versions, not just one.** It is now
  a matrix over the two big Supabase clusters, **2.9.1** (~224 projects) and **2.16.1** (~434), on PG15
  (set `TS_VERSIONS` to override). The full track passes on both, confirming the migration (including the
  `drop_chunks` retention auto-translation, which reads the version-sensitive jobs catalog) works on 2.9.1.
- **`from_hypertable` exposes its phases, with an online append-only catch-up.** The migration is split
  into `from_hypertable_copy` (build the destination and bulk-copy the existing chunks to a watermark,
  source stays live) and `from_hypertable_cutover` (catch up rows that arrived after the watermark, swap
  the copy in, hand off to transmute); `from_hypertable` runs both back to back. Driving them separately
  lets writes keep arriving during the migration: appends written between copy and cutover (control > the
  copy watermark) are caught up at cutover, so no row is lost. (tests/timescale/db/05)
- **`from_hypertable` preserves identity columns.** A hypertable with an identity/sequence column (e.g. a
  composite `(id, ts)` PK with `id GENERATED ... AS IDENTITY`) kept losing it on migration: `CREATE TABLE
  (LIKE ...)` does not carry identity, so the destination's column became a plain column and inserts that
  omitted it failed. `from_hypertable` now captures the source's identity columns and re-establishes the
  property on the destination before the transmute handoff (which reseeds the sequence past the max
  migrated value), so writes that omit the column keep auto-generating without collision. Normalised to
  `GENERATED BY DEFAULT`, matching transmute. (tests/timescale/db/04)

- **`transmute` partitions keyless tables; `from_hypertable` migrates keyless hypertables.** The key is
  now optional: the only hard requirement is a **`NOT NULL` control column**. A primary key or unique
  constraint that includes the control column is still reused in place when present, but a table with
  neither is now partitioned **keyless** (no key synthesized, faithful to the source) instead of refused.
  This is the common "Timescale as a partition manager" shape -- `create_hypertable` makes the time column
  `NOT NULL` but adds no key -- so `from_hypertable` drops its keyless refusal and migrates those
  hypertables (tests/timescale/db/03; tests/timescale/db/01 updated). A nullable control column, a key that
  *excludes* the control column, and a bare unique index are still refused with guidance. One limitation:
  `refine` is unavailable on a keyless monolith (no key to dedup a resumable copy), so its history stays as
  one coarse, queryable child; `refine` raises a clear error rather than failing obscurely. (tests/52;
  tests/32 removed as obsolete, tests/25 updated.)
- **`refine` reuses the same key `transmute` did (bug fix).** `refine`'s resumable copy identifies rows by
  the reused key, but it was built from the **primary key only** -- so on a monolith whose reused key is a
  *unique constraint* (the case the previous entry added) it produced malformed SQL (`... where )`) and
  failed. It now uses the primary key or the unique constraint, matching `transmute`. (tests/53)
- **`transmute` reuses a unique constraint, not just a primary key.** The key contract is relaxed: the
  control column must be part of a **primary key OR a unique constraint** (Postgres requires a partitioned
  table's key only to *include* the partition key). `transmute` reuses whichever exists in place, with no
  rebuild: the parent adopts the monolith's existing constraint index (`ADD PRIMARY KEY` adopts a child PK
  index, `ADD UNIQUE` adopts a child unique-constraint index; both metadata-only, verified on PG 15-18).
  This is faithful -- no primary key is synthesized when the source had only a unique constraint -- and it
  unblocks tables (e.g. time-series with a `UNIQUE (device_id, ts)` and no PK) that previously could not be
  partitioned at all. The control column it covers is required to be `NOT NULL` (a primary key guarantees
  this; for a unique constraint it is checked, never scanned). A *bare* unique index (not a constraint) is
  refused with guidance to promote it metadata-only via `ADD CONSTRAINT ... UNIQUE USING INDEX` (`ADD
  UNIQUE` would otherwise rebuild it); a table with no primary key and no usable unique constraint is still
  refused. Incoming-FK preservation now accepts an FK that references the reused unique constraint, not
  only the primary key. (tests/49-51; tests/32 updated for the relaxed contract)
- **The bounded-child transmute redesign: the original table becomes a "monolith" partition, not the
  `DEFAULT`; the history is split on demand by `refine`.** This supersedes the metadata-only-cutover and
  `DEFAULT`-as-store framing of the entries below. `transmute` now renames the original aside and attaches
  it, intact, as one bounded coarse **monolith** child covering `[grid_floor(min), B)`, under a fresh
  **empty `DEFAULT`** safety net: still no row movement, but the cutover does one online, read-only
  `VALIDATE` scan (under a non-blocking `SHARE UPDATE EXCLUSIVE` lock) before the brief metadata-only
  rename/attach. The historical bulk no longer drains row-by-row; it stays in the monolith until
  **`refine()`** splits it into proper partitions by **copying** (no dead tuples, no vacuum), atomically
  (synchronous `refine` / `refine_history`) or paced across maintenance ticks (`set_refine` auto-refine,
  budget-feathered like the drain). Refine is retention-aware (below-horizon sub-ranges are skipped, not
  materialized) and optional (a coarse monolith is a correct, permanent state). The drain is demoted to the
  **assistant**: it keeps the empty `DEFAULT` empty by evacuating strays, so `obtain` takes a cheap
  scan-free attach. `status()` gains `coarse_partitions` and `history_unrefined` (the refinement backlog);
  `untransmute`'s gate is now monolith/data-based (reversible until a row lands outside the monolith or
  refinement begins); `maintain` suspends preserve-managed incoming FKs around the drain's row movement (a
  copy-`refine` needs no such leash; its swap handles the FK atomically -- see the refine-copy fix below).
  Partitions wider than one step are named `_p<lo>_to_<hi>`. (PRs #116-#119, #123; tests/42-47; REDESIGN.md)
- **`refine` copies instead of moving (correctness fix for the redesign above).** The first implementation
  of `refine_step` was inadvertently a clone of the drain: it `DELETE`d rows out of the coarse source and
  re-`INSERT`ed them into unattached children, contradicting the design's *copy, never delete*. That bloated
  the source with dead tuples and reopened the `snapshot()` read gap that copy-then-swap exists to avoid --
  a paced auto-refine **undercounted** the parent mid-refine. `refine_step` now **copies** each frozen
  sub-range into a standalone born-validated child (budget-sized anti-join `INSERT`s resumed from the
  child's high-water mark, progress tracked across ticks by a new `config.refine_cursor`) and **skips**
  below-horizon sub-ranges without deleting (discarded with the source at the swap); the source stays whole
  and **attached** until one atomic swap, so a read of the parent is never short. Three consequences follow
  from the source staying attached: `snapshot()` no longer unions a refine's copy-children (their rows are
  still in the monolith, so it would double-count); `restore_incoming_fks` no longer counts them as in-flight
  drain children; and `maintain` no longer suspends an incoming FK for a refine. The multi-tick copy needs no
  FK leash -- only the swap's `DETACH` does (Postgres refuses to detach a partition whose rows are still
  referenced), so the swap transiently drops and re-adds the FK within its one atomic transaction (no visible
  RI window, unlike the drain's). Log actions are `refine_copy` / `refine_aged` (were `refine_move` /
  `refine_reclaim`). (PR #128; new tests/48, tests/47 rewritten, tests/07/45/46 updated)
- **Docs rewritten for the monolith model; `DESIGN.md` retired.** The reference, guide, README, and runbook
  are rewritten from scratch against the current API; `REDESIGN.md` is now the canonical design note (the
  original `DESIGN.md`'s enduring supply/demand operating model is folded into it) and `DESIGN.md` is
  removed.

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
- **Docs: clarified that retention is a standing floor, not just an aging process (issue #97, closed as
  working-as-intended).** A row inserted with a control value already past the horizon (a backdated or
  late-arriving event) is reclaimed by the next maintenance cycle, exactly as any retention system would
  drop it -- the `INSERT` succeeds and a later transaction removes it per the policy you set. To keep
  late-arriving data, retain on an ingestion timestamp or widen the window. Pinned by tests/40.
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
