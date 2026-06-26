# Design: `from_hypertable` (migrating a TimescaleDB hypertable to a pgpm-managed native partition set)

Status: Draft / proposed
Scope: single time-or-monotonic RANGE dimension, TimescaleDB Apache 2 Edition

## Motivation

Supabase ships TimescaleDB Apache 2 Edition and has deprecated it: the extension is gone on Postgres 17 and supported only on Postgres 15, which must drop it before upgrading. The affected population is therefore projects on PG15 (and soon PG14) being pushed off the extension, on older Apache builds. Supabase's own guidance points these users at pg_partman. This document specifies an alternative path that lands them on pg_partition_magician instead, in the coarse-monolith state pgpm is designed around, so the "refine later or never" story applies to migrated tables verbatim.

The target user is someone using Timescale "mainly as a partition manager": time-ordered, RANGE-compatible data, a retention policy, and little or none of Timescale's analytical machinery.

## Why a full copy, and not chunk reattachment

A hypertable is not native declarative partitioning. It is PostgreSQL table inheritance plus Timescale's own catalog and planner hooks. That rules out pointing pgpm's native-partition operators at it directly. Two migration families exist:

1. **Reattach**: detach each chunk from the hypertable and `ATTACH` it as a native partition. Low I/O, but it is floored at TimescaleDB 2.21 (the first version with supported `detach_chunk`), it is blocked by compressed chunks, and it depends on Timescale catalog internals. For the Supabase population this is a dead end: they are on older builds, below the `detach_chunk` floor.

2. **Full copy** (this design): read every row out of the hypertable into a new plain table, swap it in, drop the hypertable, then transmute. Higher I/O, but version-agnostic and catalog-agnostic.

Two facts make the full copy clean for this population specifically. Apache Edition has no compression (the columnstore is a Community feature), so the copy reads through Timescale's ordinary SELECT path with no decompression and the transient disk cost is roughly 2x the logical size rather than a multiple of a compressed footprint. And Timescale does not permit foreign keys that *reference* a hypertable (only FKs from the hypertable to normal tables), so there are no incoming FKs to drop and recreate at cutover. The hardest parts of the general problem are absent here.

## Core idea: un-hypertable, then transmute

`from_hypertable` does not copy into a pre-partitioned parent and route rows during the load. It copies into a plain unpartitioned heap table, swaps that table into the original name, and then calls `transmute()` on it.

This reduces the hypertable migration to a problem pgpm already solves. Once the data is in an equivalent plain table under the original name, it is exactly transmute's input: rename aside as the bounded monolith, stand up the native partitioned parent, attach the monolith after one online validate scan, register paused. Everything downstream (obtain, drain, retain, refine) is unchanged. `from_hypertable` is therefore a thin front end whose only job is to get the data out of the hypertable and into a faithful plain copy.

## Procedure

### 1. Pre-flight checks (refuse loudly)

Refuse the migration, with a clear message, if any of these hold:

- **Continuous aggregates exist** on the hypertable (`timescaledb_information.continuous_aggregates`). There is no native-partition equivalent and silently dropping them is data-destructive from the user's point of view.
- **More than one dimension** is configured (space partitioning via `add_dimension`). pgpm is single-key RANGE; a space-partitioned hypertable is out of scope.
- **The control column is not in the table's primary key.** A well-formed hypertable already satisfies this, since Timescale requires the partitioning column in any unique constraint, so this is a sanity check rather than a likely failure.
- **Insufficient free disk.** Require free space of at least the logical size of the table plus its indexes. For Apache (uncompressed) this is the size you can read directly from the standard size functions.

Detect, and warn but proceed, if:

- The newest chunk's upper bound does not fall on the grid the user wants going forward. This is the single frontier seam; it is handled at transmute/obtain time by making the first new partition a one-off irregular partition that begins where history ends, then snapping to the grid after it.

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

The time predicate triggers Timescale chunk exclusion, so each batch reads exactly one chunk. Per-batch commits bound transaction size and WAL, give natural progress reporting, and let autovacuum keep up. `ORDER BY <control>` makes the destination physically time-clustered, which makes the later transmute validate scan and any refine cheaper. This mirrors what pg_partman's `partition_data_proc` does and the reason its docs suggest CLUSTER first; here the clustering is free from the copy order.

### 4. Indexes and key

After the bulk copy, build the secondary indexes and add the primary key (which includes the control column, replicating the hypertable's PK). The destination is not serving traffic, so plain `CREATE INDEX` is fine and blocks no one. Building indexes here, before cutover, keeps the cutover lock short.

### 5. Live-write delta

This is where the copy approach gives up transmute's zero-downtime property, and the doc should say so plainly.

- **Append-only workload (the common case):** the bulk copy covered all rows with `control <= T0`, where `T0` is the copy start watermark. After the copy, tail-copy the rows in `(T0, now]` in one or two shrinking passes. No change capture needed.
- **General workload (updates or deletes to historical rows):** install an `AFTER INSERT/UPDATE/DELETE` trigger on the hypertable at the start that logs row-level changes to a delta table, and replay it (idempotently) before cutover. This is the standard ghost-table online-migration pattern and is the harder mode; flag it rather than assume append-only.

### 6. Cutover (the only non-online window)

In one transaction holding a brief exclusive lock on the source:

1. `LOCK TABLE <hypertable> IN ACCESS EXCLUSIVE MODE;`
2. Final tail catch-up (append-only) or final delta replay (general).
3. If a sequence/identity was in use, capture its current value.
4. `DROP TABLE <hypertable>;` This drops the chunks and clears Timescale's catalog entries via its event trigger. No manual `_timescaledb_catalog` editing.
5. `ALTER TABLE <dest> RENAME TO <original_name>;` and reset any sequence/identity to the captured value so new writes continue unbroken.
6. `COMMIT;`

After commit, the original name resolves to a working plain table and the application is unaffected. The lock window is just the final catch-up plus a drop and a rename.

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

transmute renames it aside as the bounded monolith, builds the native partitioned parent, attaches the monolith after one online validate scan, and registers it paused. From here it is ordinary pgpm: `resume`, `obtain` ahead of the frontier, and `refine` on the operator's schedule or never.

### 8. Retention policy translation

Read the existing Timescale retention policy (the `drop_chunks` policy interval) and translate it directly into pgpm's `retain` config so the user's data-lifecycle intent carries over instead of being silently lost on extension removal.

## Locking and online-ness summary

- Bulk copy (step 3): fully online. Reads the source, writes a separate destination; the source serves traffic throughout.
- Index build (step 4): online; the destination is not yet serving.
- Delta capture trigger (step 5, general mode only): small write overhead on the source during the migration.
- Cutover (step 6): brief `ACCESS EXCLUSIVE` on the source for the final catch-up, drop, and rename. This is the only downtime.
- Transmute (step 7): online; its own brief metadata step plus an online (`SHARE UPDATE EXCLUSIVE`) validate scan.

## Resource requirements

Peak disk is the source plus the full destination copy and its indexes, held until the cutover drops the source: roughly 2x logical size plus index overhead. For Apache (uncompressed) this is straightforward to estimate up front. Total I/O is one full sequential read of the data plus one rewrite, plus the transmute validate scan.

## Failure and rollback

Up to the cutover transaction, the source hypertable is untouched and serving traffic and the destination is a separate object. If any step before cutover fails, drop the destination and nothing is lost. The cutover transaction (drop source, rename destination) is the only irreversible step, and it either commits whole or rolls back whole. Recommend a verification gate before cutover: row counts match per chunk range, and a checksum or sampled comparison on a few ranges.

## Honest tradeoffs

This is a one-time full copy. It costs about 2x disk transiently, a real read-and-rewrite of all data, and a brief cutover lock rather than the pure metadata flip transmute gives a normal table. What it buys is total independence from Timescale's version and catalog internals, which is exactly right for a population stuck on old Apache builds being force-migrated off the extension. Where transmute's appeal is "no movement," `from_hypertable`'s appeal is "no dependence on Timescale," and it pays for that with movement.

## Positioning versus pg_partman

Supabase already points departing Timescale users at pg_partman. The case for landing on pgpm instead is the bounded-monolith design documented elsewhere in this repo: the migration ends in a coarse-but-correct monolith that does not have to be refined on a deadline, whereas the pg_partman online path attaches history as the default and obligates prompt draining. For a user who just wants time partitioning plus retention going forward and can tolerate coarse history, the migrated end state is lower-effort on pgpm. The companion comparison piece makes this argument in full; `from_hypertable` is what delivers a Timescale user into it.

## Open questions and test matrix

- Confirm `DROP TABLE <hypertable>` cleanly removes chunks and catalog rows on the oldest Apache versions in the Supabase PG15 fleet, not just current ones.
- Confirm time-predicate chunk exclusion drives single-chunk reads on those same old versions, so the batched copy stays one-chunk-per-batch.
- Identity/serial handling: composite PK of `(id, control)` with a sequence; verify capture-and-reset at cutover keeps new inserts unbroken.
- Verify the no-incoming-FK assumption holds for the versions in scope (Timescale disallows FKs referencing a hypertable, so this should be safe, but confirm against the actual fleet).
- Decide the supported floor. The copy path should work on any version since it is only SELECT plus DROP TABLE; pick a tested minimum and refuse below it rather than guess.
- Benchmark the copy on a representative large table to put real numbers on wall-clock and peak disk, for the "honest tradeoffs" section.
