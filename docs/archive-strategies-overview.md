# Choosing an archival strategy

Three pages on this project ([Archive partitions to S3](archive-to-s3.md), [The archive
assistant](archive-assistant.md), [Chunked, cross-partition Parquet
archival](archive-chunked-parquet.md)) each build a way to copy a partition's rows to S3 before
retention drops it. Read together, that can look like a pile of unrelated mechanisms. It isn't:
there are really only **two architectures**. One of them (the synchronous hook) is a single,
structurally fixed shape. The other (a paced worker with a ledger) has two independent knobs,
and today's docs happen to build two of its four possible configurations -- which, because they
differ on *both* knobs at once, read as two unrelated designs rather than two corners of the same
small space. This page exists to help you pick an architecture and a configuration before diving
into any one page's mechanics -- it does not replace those pages, and it does not introduce
anything new.

## The synchronous hook

[`pgpm.retain`](reference.md#retain) (or a direct [`pgpm.retire`](reference.md#retire) call)
decides to drop a partition and calls a `pre_drop` hook that does the archiving *inline*, inside
that same drop's transaction. One partition, one file, archived at the exact moment it's dropped
-- the simplest mental model on this page. The cost: the vacuum-horizon hold spans the whole
read-and-upload of that partition, because the hook runs inside `retain()`'s transaction and a
snapshot pins the horizon for as long as the statement holding it runs, network time included.
Built as `archive.to_s3` (NDJSON) and `archive.to_s3_parquet` (Parquet).

This architecture is structurally walled off from the other one, not just built differently from
it. A `pre_drop` hook is a nested call inside `retain()`'s already-open transaction, and PL/pgSQL
forbids issuing `COMMIT` from inside a block reachable that way -- so a synchronous hook can never
bound its own vacuum-horizon hold by committing between chunks of work, no matter how it's
rewritten. Bounding the hold requires *not* being a nested hook call: being an independently
invoked procedure instead, driven by cron or called directly, is what the other architecture buys.

## The paced worker

Both `docs/archive-assistant.md` and `docs/archive-chunked-parquet.md` build the same underlying
shape: an independently invoked procedure (cron-paced or called on demand) that archives *ahead
of* any drop, commits between chunks of work to bound the vacuum-horizon hold, and records what
it's archived in a ledger. Two knobs choose the rest:

- **Boundary rule** -- what counts as one archived unit. *Partition-aligned*: the unit is always
  exactly one partition, however big it turns out to be. *Byte-budget-aligned*: the unit is
  whatever range of rows lands close to a target byte budget, regardless of where partition
  boundaries fall -- one file might cover part of an oversized partition, or several small ones.
- **Drop-trigger rule** -- who decides when a partition actually gets dropped. *Gate-only*: the
  worker never calls `retire()` itself; it just keeps its ledger ahead of `retain()`'s own
  schedule and registers a `pre_drop` hook that vetoes a drop if the ledger hasn't caught up yet.
  *Self-driving*: the worker finds retention-eligible partitions itself and calls
  [`pgpm.retire()`](reference.md#retire) directly once archived, registering a gate hook only as
  defense in depth against anyone else's `retain()` calls landing on the same partition.

These two knobs are independent, so there are four possible configurations. Two are built today:

| | Gate-only (`retain()` drives the drop) | Self-driving (the worker calls `retire()` itself) |
|---|---|---|
| **Partition-aligned** | Not built. A real combination -- the assistant's per-part-commit horizon bound, without the assistant also owning drop timing -- just not one anyone has asked for. | Built: the archive assistant (`archive.partition`/`archive.scan`), NDJSON only. |
| **Byte-budget-aligned** | Built: the chunker (`archive._chunk_one`/`chunk_step`/`chunk_all` + `archive.file_gate`), Parquet only, GZIP default-on. | Not built. The chunker already knows (via the same watermark check the gate uses) when a range fully covers a partition; teaching it to call `retire()` itself once that's true is a small addition on what already exists, not a new design. This is the general form of the question [#212](https://github.com/dventimisupabase/pg_partition_magician/issues/212) already raises from the Parquet-assistant angle. |

The two built cells sit on the diagonal: they differ on both knobs simultaneously, which is
exactly why "the assistant" and "the chunker" read as two separate architectures rather than two
settings of the same two switches. Filling in either empty cell would make that visible -- at
that point the shared ledger/gate/paced-worker machinery each page hand-builds separately
(`archive.ledger` vs. `archive.file_ledger`, `archive.gate` vs. `archive.file_gate`) would be
duplicated code around the same two knobs, not genuinely different designs. Which direction that
unification would run -- the chunker growing a self-driving mode and becoming the general case,
or the assistant growing byte-budget boundaries and becoming the general case -- is an open
question this page doesn't answer; either framing arrives at the same merged shape.

## Two knobs that apply on top of either architecture

- **Format**: NDJSON or Parquet. NDJSON is universal and human-readable, parseable by anything
  that reads JSON lines. Parquet is columnar and directly queryable by DuckDB, Athena, Redshift
  Spectrum, Spark, Trino, and Snowflake with no conversion step, at the cost of being a from-scratch,
  zero-dependency writer with real limits (six types, no dictionary encoding, no statistics, one
  row group -- see [Archive partitions to S3](archive-to-s3.md#honest-limits-for-the-parquet-variant)).
- **Compression**: GZIP on or off. The compressor (`archive._pq_gzip_compress`) takes any `bytea`
  and returns a valid gzip container -- it has nothing to do with Parquet specifically. It is
  wired in (default on) everywhere Parquet is written; nowhere NDJSON is written, today (#214).

Today's format split (NDJSON for the assistant, Parquet for the chunker) is an accident of build
order, not a structural coupling -- nothing about "partition-aligned" or "byte-budget-aligned"
requires a particular format, and nothing about "gate-only" or "self-driving" does either.

One more knob, but only where it can matter:

- **Transport** (the synchronous hook only -- the paced worker already bounds file/part size a
  different way, so it doesn't need this): single PUT or multipart PUT. Multipart only helps a
  format whose reader can genuinely stream row-by-row across parts (NDJSON); it does not raise
  Parquet's ceiling, because the whole file has to be built in memory before the first part can be
  sent regardless of how many parts it's split into afterward (#211).

## What's built, what's a gap

- The synchronous hook: NDJSON built (single-PUT and multipart, no compression); Parquet built
  (single-PUT, GZIP default-on) -- multipart Parquet is an open question, not a clear gap (#211).
- The paced worker: see the boundary-rule x drop-trigger-rule table above for the two built
  configurations and the two gaps.
- Compression is its own cross-cutting gap: on for both Parquet paths, off for every NDJSON path,
  and closing that is #214.
- A byte-budget-aligned, cross-partition NDJSON worker (independent of which drop-trigger rule it
  uses) is #213.

## Choosing among them

Start from the architecture, not the format:

- Partitions are small enough (or your vacuum tolerance is loose enough) that holding the horizon
  for one partition's read-and-upload doesn't worry you: **the synchronous hook**. Pick NDJSON for
  the simplest possible consumer story, or Parquet if you want the archive directly queryable by
  an analytics engine without a conversion step.
- You want the tightest vacuum-horizon bound this project builds, one file per partition, and a
  scanner owning drop timing instead of `retain()`'s own schedule: **the archive assistant**
  (partition-aligned, self-driving). NDJSON only, today.
- Partition sizes are large or uneven, and you want file size to be a deliberate operational
  choice rather than emergent, with `retain()` still deciding when partitions actually drop:
  **the chunker** (byte-budget-aligned, gate-only). Parquet only, today.

Whichever you pick, compression is close to free to turn on wherever it's wired (it costs real,
non-trivial time -- see [Chunked, cross-partition Parquet archival's byte-budget
guidance](archive-chunked-parquet.md#the-chunker) for measured numbers -- but no design tradeoff
beyond that), and multipart transport only matters for the synchronous hook, and only really helps
NDJSON.

## Positioning

This page is a map, not a fourth mechanism. `archive.to_s3`, `archive.to_s3_parquet`,
`archive.partition`/`archive.scan`, and `archive._chunk_one`/`chunk_step`/`chunk_all` all continue
to exist exactly as their own pages describe; nothing here changes their behavior or supersedes
their own "Honest limits" sections. The reframing above (one fixed architecture, one
two-knobbed architecture with two built and two open configurations) is a way of reading what's
already there, not a proposal to merge `archive-assistant.md` and `archive-chunked-parquet.md`'s
actual code -- that would be a real, separate undertaking (shared ledger schema, shared gate
logic, one worker parameterized by both knobs instead of two hand-built ones), tracked by whichever
of the two empty cells above ends up worth building first.
