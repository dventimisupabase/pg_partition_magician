# Choosing an archival strategy

Three pages on this project ([Archive partitions to S3](archive-to-s3.md), [The archive
assistant](archive-assistant.md), [Chunked, cross-partition Parquet
archival](archive-chunked-parquet.md)) each build a way to copy a partition's rows to S3 before
retention drops it. Read together, that can look like a pile of unrelated mechanisms. It isn't:
there are three drop-ownership **patterns**, and format, compression, and transport are
independent knobs within each. This page exists to help you pick a pattern and a set of knobs
before diving into any one page's mechanics -- it does not replace those pages, and it does not
introduce anything new.

## The real choice: who owns the drop, and when does archiving happen relative to it

**Pattern A -- synchronous hook.** [`pgpm.retain`](reference.md#retain) (or a direct
[`pgpm.retire`](reference.md#retire) call) decides to drop a partition and calls a `pre_drop`
hook that does the archiving *inline*, inside that same drop's transaction. One partition, one
file, archived at the exact moment it's dropped -- the simplest mental model on this page. The
cost: the vacuum-horizon hold spans the whole read-and-upload of that partition, because the hook
runs inside `retain()`'s transaction and a snapshot pins the horizon for as long as the statement
holding it runs, network time included. Built as `archive.to_s3` (NDJSON) and
`archive.to_s3_parquet` (Parquet).

**Pattern B -- byte-budget chunker, gate-only hook.** A separate, independently-paced chunker
(`archive.chunk_step` on a cron tick, or `archive.chunk_all` on demand) archives ranges *ahead
of* any drop, sized by a target byte budget rather than by partition boundaries, committing a
ledger entry after each file. The `pre_drop` hook it registers (`archive.file_gate`) does no
archiving at all -- it only checks the ledger already covers the range about to be dropped and
vetoes the drop if not. This is the pattern where file size becomes a deliberate operational
choice instead of whatever a partition happens to be, and where one file can span parts of
several partitions. Built as the chunker in [Chunked, cross-partition Parquet
archival](archive-chunked-parquet.md) (Parquet only).

**Pattern C -- standing scanner, scanner-owned drop.** [`archive.scan()`](archive-assistant.md)
doesn't wait for `retain()`'s schedule at all: it finds retention-eligible partitions itself,
archives one partition by sub-splitting it into committed parts (bounding the horizon to
`c_part_bytes` per part instead of per partition -- measured 11 advancing `backend_xmin` values
against pattern A's 1 pinned value, same partition), and calls `pgpm.retire()` itself once fully
archived. It also registers a gate hook (`archive.gate`) as defense in depth for anyone else's
`retain()` calls, but the scanner is the primary driver, not the hook. Built as the archive
assistant (NDJSON only).

A pattern is not a free choice independent of what you're archiving: A archives exactly the
partition `retain()` is about to drop, so it can't decouple file size from partition size. B and
C both can, in principle (B already does; C could, per #212), but nothing here builds
"byte-budget chunking, and the chunker itself owns the drop" as a fourth, merged pattern -- B
still leans on `retain()`/`retire()` as the eventual drop trigger, just gated rather than
synchronous.

## Two knobs that apply within any pattern

- **Format**: NDJSON or Parquet. NDJSON is universal and human-readable, parseable by anything
  that reads JSON lines. Parquet is columnar and directly queryable by DuckDB, Athena, Redshift
  Spectrum, Spark, Trino, and Snowflake with no conversion step, at the cost of being a from-scratch,
  zero-dependency writer with real limits (six types, no dictionary encoding, no statistics, one
  row group -- see [Archive partitions to S3](archive-to-s3.md#honest-limits-for-the-parquet-variant)).
- **Compression**: GZIP on or off. The compressor (`archive._pq_gzip_compress`) takes any `bytea`
  and returns a valid gzip container -- it has nothing to do with Parquet specifically. It is
  wired in (default on) everywhere Parquet is written; nowhere NDJSON is written, today (#214).

One more knob, but only where it can matter:

- **Transport** (pattern A only -- B and C already bound file/part size a different way, so
  they don't need it): single PUT or multipart PUT. Multipart only helps a format whose reader
  can genuinely stream row-by-row across parts (NDJSON); it does not raise Parquet's ceiling,
  because the whole file has to be built in memory before the first part can be sent regardless
  of how many parts it's split into afterward (#211).

## What's built, what's a gap

| | NDJSON | Parquet |
|---|---|---|
| **A. Synchronous hook** | Built: `archive.to_s3` (single-PUT and multipart), no compression | Built: `archive.to_s3_parquet` (single-PUT, GZIP default-on); multipart is an open question, not a clear gap -- #211 |
| **B. Byte-budget chunker + gate** | Gap -- #213 | Built: the chunker (GZIP default-on) |
| **C. Standing scanner** | Built: the archive assistant, no compression | Gap -- #212 |

Compression is really its own row underneath this table: on for both Parquet cells, off for both
NDJSON cells, and closing that gap for A and C is #214.

## Choosing among them

Start from the pattern, not the format:

- Partitions are small enough (or your vacuum tolerance is loose enough) that holding the
  horizon for one partition's read-and-upload doesn't worry you: **pattern A**. Pick NDJSON if
  you want the simplest possible consumer story, or Parquet if you want the archive directly
  queryable by an analytics engine without a conversion step.
- Partition sizes are large or uneven, and you want file size to be a deliberate operational
  choice rather than emergent: **pattern B**. Parquet only, today.
- You want per-partition files (like A) but need the tightest vacuum-horizon bound this project
  builds, and you're fine with a scanner owning the drop timing instead of `retain()`'s own
  schedule: **pattern C**. NDJSON only, today.

Whichever pattern, compression is close to free to turn on wherever it's wired (it costs real,
non-trivial time -- see [Chunked, cross-partition Parquet archival's byte-budget
guidance](archive-chunked-parquet.md#the-chunker) for measured numbers -- but no design tradeoff
beyond that), and multipart only matters for pattern A, and only really helps NDJSON.

## Positioning

This page is a map, not a fourth mechanism. `archive.to_s3`, `archive.to_s3_parquet`,
`archive.partition`/`archive.scan`, and `archive._chunk_one`/`chunk_step`/`chunk_all` all
continue to exist exactly as their own pages describe; nothing here changes their behavior or
supersedes their own "Honest limits" sections. Read this page first to decide which one you
want, then read that page for the mechanics.
