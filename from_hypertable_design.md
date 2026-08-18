# Design: `from_hypertable` (migrating a TimescaleDB hypertable to a pgpm-managed native partition set)

> **Frozen artifact: not current documentation.** A point-in-time record, kept for history and not
> maintained against the code, so it describes the system as it stood when written. For how
> pg_partition_magician works today see the [user guide](docs/guide.md) and the
> [reference](docs/reference.md).

Status: Implemented (online copy, online pre-drain of the live-write backlog, brief cutover, transmute handoff). See `docs/reference.md` for the function reference and `CHANGELOG.md` for the changes.
Scope: single time-or-monotonic RANGE dimension, TimescaleDB Apache 2 Edition

## Motivation

Supabase ships TimescaleDB Apache 2 Edition and has deprecated it: the extension is gone on Postgres 17 and supported only on Postgres 15, which must drop it before upgrading. The affected population is therefore projects on PG15 (and soon PG14) being pushed off the extension, on older Apache builds. Supabase's own guidance points these users at pg_partman. This document specifies an alternative path that lands them on pg_partition_magician instead, in the coarse-monolith state pgpm is designed around, so the "regrain later or never" story applies to migrated tables verbatim.

The target user is someone using Timescale "mainly as a partition manager": time-ordered, RANGE-compatible data, a retention policy, and little or none of Timescale's analytical machinery.

## Why a full copy, and not chunk reattachment

A hypertable is not native declarative partitioning. It is PostgreSQL table inheritance plus Timescale's own catalog and planner hooks. That rules out pointing pgpm's native-partition operators at it directly. Two migration families exist:

1. **Reattach**: detach each chunk from the hypertable and `ATTACH` it as a native partition. Low I/O, but it is floored at TimescaleDB 2.21 (the first version with supported `detach_chunk`), it is blocked by compressed chunks, and it depends on Timescale catalog internals. For the Supabase population this is a dead end: they are on older builds, below the `detach_chunk` floor.

2. **Full copy** (this design): read every row out of the hypertable into a new plain table, swap it in, drop the hypertable, then transmute. Higher I/O, but version-agnostic and catalog-agnostic.

Two facts make the full copy clean for this population specifically. Apache Edition has no compression (the columnstore is a Community feature), so the copy reads through Timescale's ordinary SELECT path with no decompression and the transient disk cost is roughly 2x the logical size rather than a multiple of a compressed footprint. And Timescale does not permit foreign keys that *reference* a hypertable (only FKs from the hypertable to normal tables), so there are no incoming FKs to drop and recreate at cutover. The hardest parts of the general problem are absent here.

## Core idea: un-hypertable, then transmute

`from_hypertable` does not copy into a pre-partitioned parent and route rows during the load. It copies into a plain unpartitioned heap table, swaps that table into the original name, and then calls `transmute()` on it.

This reduces the hypertable migration to a problem pgpm already solves. Once the data is in an equivalent plain table under the original name, it is exactly transmute's input: rename aside as the bounded monolith, stand up the native partitioned parent, attach the monolith after one online validate scan, register paused. Everything downstream (obtain, drain, retain, regrain) is unchanged. `from_hypertable` is therefore a thin front end whose only job is to get the data out of the hypertable and into a faithful plain copy.

## Procedure

### 1. Pre-flight checks (refuse loudly)

Refuse the migration, with a clear message, if any of these hold:

- **Continuous aggregates exist** on the hypertable (`timescaledb_information.continuous_aggregates`). There is no native-partition equivalent and silently dropping them is data-destructive from the user's point of view.
- **More than one dimension** is configured (space partitioning via `add_dimension`). pgpm is single-key RANGE; a space-partitioned hypertable is out of scope.
- **The control column does not exist** on the table. This is the only column requirement the pre-flight enforces; the key/`NOT NULL` contract is left to `transmute`, the single source of truth (it reuses a primary key or unique constraint that includes the control column, else partitions the table **keyless** -- the common hypertable shape, since `create_hypertable` makes the time column `NOT NULL` but adds no key). So a keyless hypertable migrates; a key that *excludes* the control column, a nullable control column, or a bare unique index are refused later by `transmute`. (Change tracking, `p_track_changes`, additionally needs a key to reconcile by, so it is refused on a keyless table and on a key with a nullable non-control column -- see §5.)

Warn but proceed (informational `NOTICE`s, never refusals), reporting:

- **The transient disk and the estimated copy time.** The copy writes a full second table, so it needs roughly the source's current on-disk size in extra space until cutover drops the hypertable; `from_hypertable_disk_estimate` / `from_hypertable_time_estimate` report these (and are callable on their own for sizing ahead of time). Informational, so the operator decides -- not a hard refusal.
- **The newest chunk's upper bound not falling on the grid** the user wants going forward. This is the single frontier seam; it is handled at transmute/obtain time by making the first new partition a one-off irregular partition that begins where history ends, then snapping to the grid after it.

### 2. Build the destination plain table

Create the destination with structure but deliberately without indexes, so the bulk load is not maintaining indexes per row:

```sql
CREATE TABLE <dest> (LIKE <hypertable>
    INCLUDING DEFAULTS
    INCLUDING CONSTRAINTS
    INCLUDING GENERATED
    INCLUDING COMMENTS);
```

Indexes and the primary key are added after the bulk copy (step 4). Record any sequence or identity definitions on the source so they can be reproduced and reset at cutover.

### 3. Chunk-bounded batched copy

Enumerate the source's chunk time ranges (`show_chunks`) and copy one chunk-range per batch, committing between batches:

```sql
INSERT INTO <dest>
SELECT * FROM <hypertable>
WHERE <control> >= <chunk_lo> AND <control> < <chunk_hi>
ORDER BY <control>;
```

The time predicate triggers Timescale chunk exclusion, so each batch reads exactly one chunk. Per-batch commits bound transaction size and WAL, give natural progress reporting, and let autovacuum keep up. `ORDER BY <control>` makes the destination physically time-clustered, which makes the later transmute validate scan and any regrain cheaper. This mirrors what pg_partman's `partition_data_proc` does and the reason its docs suggest CLUSTER first; here the clustering is free from the copy order.

### 4. Indexes and key

After the bulk copy, build the secondary indexes and add the primary key (which includes the control column, replicating the hypertable's PK). The destination is not serving traffic, so plain `CREATE INDEX` is fine and blocks no one. Building indexes here, before cutover, keeps the cutover lock short.

When change tracking is on, the copy pre-builds the **reused-key index once**, with the temp name and definition the cutover will adopt, so the online delta drain (step 5) uses it for its per-batch key lookups and the cutover adopts it (`ALTER TABLE ... USING INDEX`, metadata-only) rather than rebuilding it. That is one key-index build instead of a throwaway-then-rebuild, all off the lock; the cutover's pre-build loop is re-entrant (it skips an index that already exists). Secondary indexes are still built at cutover, off the lock.

### 5. Live-write delta and the online pre-drain

Writes keep arriving while the copy runs; the catch-up has two modes, and in both the backlog is drained
**online, in bounded micro-batches, before the cutover takes its lock**, so the locked window applies only a
tiny residual instead of the whole-copy backlog.

- **Append-only workload (the default):** the bulk copy reads each chunk up to the current head (it reads
  the current chunk last), so almost every row appended during the copy is captured as the copy goes; only
  the small tail written past the copy watermark remains. No change capture is needed.
- **General workload (updates or deletes to already-copied rows):** pass `p_track_changes => true`. The copy
  installs an `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the touched **key** values
  (plus a monotonic `pgpm_seq` ordering column) to a `<rel>_pgpm_delta` table. Reconciliation is by the key
  transmute reuses, so tracking is refused on a keyless table and on a key with a nullable (non-control)
  column (a NULL key component can never be matched by the row-constructor reconcile, so the change would be
  lost — refuse rather than lose it).

The cutover runs the pre-drain automatically (`p_predrain`, default true); operators can also drive it by
hand during a long two-phase window. The drivers commit per batch (so WAL recycles) and stop once the
residual is at or below a threshold, with a convergence budget (`p_max_iter`) that fails loudly if the
workload dirties keys faster than the drain clears them:

- **Tracking — `from_hypertable_drain_delta` / `_step`:** reconcile each touched key against the live source
  (delete its copied row from the destination, reinsert its current source row), which is idempotent and
  order-independent per key. Each batch **delete-RETURNS** its keys from the delta as the authority and
  reconciles exactly those — so a change is never deleted-without-applying. (This is the safe construction:
  the obvious "reconcile keys, then delete them" two-snapshot variant is **unsafe** under READ COMMITTED — a
  low-`pgpm_seq` straggler that commits between the two statements gets deleted without being applied.) The
  source read is bounded to the batch's control range as literal constants, for chunk exclusion.
- **Append-only — `from_hypertable_drain_appends` / `_step`:** purely additive — copy the rows past the
  copy watermark in batches that advance the watermark (inclusive of ties at each batch bound, so none is
  split). No delta, no reconcile, no key, no destination index needed.

The final pass under the lock (step 6) is the **correctness backstop**: it re-derives the residual after the
exclusive lock is held, when no new write can commit, so anything the online pre-drain did not reach is
still applied exactly once.

### 6. Cutover (the only non-online window)

The online pre-drain (step 5) runs first, outside the lock, shrinking the catch-up backlog to a tiny
residual. Then, in one transaction holding a brief exclusive lock on the source:

1. `LOCK TABLE <hypertable> IN ACCESS EXCLUSIVE MODE;`
2. Apply the final **residual** — only the keys/rows that arrived since the pre-drain (a tracked-delta
   reconcile, or the appended tail past the watermark), bounded by one batch interval, not the copy
   duration. (For append-only the catch-up watermark is read just *before* the lock, off the locked window,
   so a keyless destination's `max(control)` scan is not held under the lock.)
3. If a sequence/identity was in use, capture its current value.
4. `DROP TABLE <hypertable>;` This drops the chunks and clears Timescale's catalog entries via its event trigger. No manual `_timescaledb_catalog` editing.
5. `ALTER TABLE <dest> RENAME TO <original_name>;`, adopt the pre-built indexes (step 4) as the original PK/UNIQUE constraints and secondary indexes (metadata-only), and reset any sequence/identity to the captured value so new writes continue unbroken.
6. `COMMIT;`

After commit, the original name resolves to a working plain table and the application is unaffected. Because
the backlog is pre-drained online and the indexes are pre-built off the lock, the locked window is just the
tiny residual plus a drop and a rename. Measured at 40M rows under continuous load, the online pre-drain
shortened the `ACCESS EXCLUSIVE` window ~3.2x on the tracking path; the append-only window was already brief
(see `bench/result-fh-cutover-lockwindow.md`).

### 7. Transmute handoff

The table under the original name is now an ordinary large plain heap table, which is transmute's input:

```sql
SELECT pgpm.transmute(
  p_parent   => '<original_name>',
  p_control  => '<control>',
  p_interval => <interval>,
  p_obtain   => <n>,
  p_retain   => <retention>  -- see step 8
);
```

transmute renames it aside as the bounded monolith, builds the native partitioned parent, attaches the monolith after one online validate scan, and registers it paused. From here it is ordinary pgpm: `resume`, `obtain` ahead of the frontier, and `regrain` on the operator's schedule or never.

### 8. Retention policy translation

Read the existing Timescale retention policy (the `drop_chunks` policy interval) and translate it directly into pgpm's `retain` config so the user's data-lifecycle intent carries over instead of being silently lost on extension removal.

## Locking and online-ness summary

- Bulk copy (step 3): fully online. Reads the source, writes a separate destination; the source serves traffic throughout.
- Index build (step 4): online; the destination is not yet serving.
- Delta capture trigger (step 5, `p_track_changes` mode only): small write overhead on the source during the migration.
- Online pre-drain (step 5): fully online, commits per batch; reconciles/copies the catch-up backlog into the destination before the lock so the locked window stays tiny.
- Cutover (step 6): brief `ACCESS EXCLUSIVE` on the source for the final **residual** (not the whole backlog — the pre-drain already moved that, online), the drop, and the rename. This is the only downtime.
- Transmute (step 7): online; its own brief metadata step plus an online (`SHARE UPDATE EXCLUSIVE`) validate scan.

## Resource requirements

Peak disk is the source plus the full destination copy and its indexes, held until the cutover drops the source: roughly 2x logical size plus index overhead. For Apache (uncompressed) this is straightforward to estimate up front. Total I/O is one full sequential read of the data plus one rewrite, plus the transmute validate scan.

## Failure and rollback

Up to the cutover transaction, the source hypertable is untouched and serving traffic and the destination is a separate object. If any step before cutover fails, drop the destination and nothing is lost. The cutover transaction (drop source, rename destination) is the only irreversible step, and it either commits whole or rolls back whole. Recommend a verification gate before cutover: row counts match per chunk range, and a checksum or sampled comparison on a few ranges.

## Honest tradeoffs

This is a one-time full copy. It costs about 2x disk transiently, a real read-and-rewrite of all data, and a brief cutover lock rather than the pure metadata flip transmute gives a normal table. The lock is kept brief on purpose: the indexes are pre-built off the lock and the live-write backlog is pre-drained online before it (step 5), so only a tiny residual is applied under the lock, and the window does not grow with the copy duration (measured ~3.2x shorter at 40M; see `bench/result-fh-cutover-lockwindow.md`). What it buys is total independence from Timescale's version and catalog internals, which is exactly right for a population stuck on old Apache builds being force-migrated off the extension. Where transmute's appeal is "no movement," `from_hypertable`'s appeal is "no dependence on Timescale," and it pays for that with movement.

## Positioning versus pg_partman

Supabase already points departing Timescale users at pg_partman. The case for landing on pgpm instead is the bounded-monolith design documented elsewhere in this repo: the migration ends in a coarse-but-correct monolith that does not have to be regrained on a deadline, whereas the pg_partman online path attaches history as the default and obligates prompt draining. For a user who just wants time partitioning plus retention going forward and can tolerate coarse history, the migrated end state is lower-effort on pgpm. The companion comparison piece makes this argument in full; `from_hypertable` is what delivers a Timescale user into it.

## Status of the open questions

Resolved (implemented + tested; the from_hypertable track runs in the default CI matrix on the Apache
`supabase/postgres` image, and the at-scale runs are on green):

- **`DROP TABLE <hypertable>` cleanly removes chunks + catalog** — verified on the pinned fleet image
  (the cutover drops the hypertable and no `_timescaledb` catalog row survives; tests/timescale/db/02,10).
- **Time-predicate chunk exclusion drives single-chunk reads** — the copy iterates chunk ranges as
  designed; confirmed end to end at 10M/40M (`bench/result-fh-cutover-lockwindow.md`).
- **Identity/serial capture-and-reset** — a composite `(id, control)` PK with a sequence migrates and keeps
  the next value collision/gap-free, including when the source sequence sits ahead of `max(id)`
  (tests/timescale/db/04, 11).
- **No-incoming-FK assumption** — Timescale disallows FKs referencing a hypertable; relied on, not refuted.
- **Copy benchmark / real numbers** — the at-scale lock-window bench (`bench/run_fh.sh`,
  `bench/result-fh-cutover-lockwindow.md`) gives wall-clock copy/cutover/lock-window figures at R2/R3.

Still open:

- **Oldest-version coverage.** The default CI leg pins one Apache TimescaleDB version (2.16.1); the older
  fleet cluster (2.9.x) is not yet a standing CI leg — confirm DROP/exclusion behavior there before
  claiming that floor (deferable via a manual dispatch with a 2.9.1-bundling image tag).
- **Supported floor.** Pick and document a tested minimum TimescaleDB/PG version rather than guess.
