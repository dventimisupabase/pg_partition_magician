# Choosing an archival strategy

Two pages on this project ([Archive partitions to S3](to-s3.md) and [Chunked, cross-partition
Parquet archival](chunked-parquet.md)) each build a way to copy a partition's rows to S3 before
retention drops it. There are really only **two architectures** now, one call away from each
other in terms of effort, but structurally different in what they guarantee:

- **The synchronous functions** (`archive.to_s3`, `archive.to_s3_parquet`): called directly, by
  you, whenever you decide to archive a partition. Simplest mental model, but nothing ties the
  call to a drop -- archiving first is entirely your own script's discipline to keep.
- **`pgpm.config.archive_fn`** (the byte-budget chunked strategy this module ships,
  `pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet`): set once per table, and
  `pgpm.maintain()` drives it automatically, ahead of every drop, in bounded chunks.
  `pgpm.retire()` will not drop a partition until this strategy reports it fully covered -- no
  registration, no separate schedule, no gate to wire up yourself.

This page exists to help you pick between them (and the format/compression knobs that apply to
both) before diving into either page's mechanics; it does not replace those pages or introduce a
third mechanism of its own.

## The synchronous functions

[`archive.to_s3`/`archive.to_s3_parquet`](to-s3.md) read and upload one partition in a single
call, whenever you call them -- no ledger, no automatic scheduling, and (since `pgpm.hook` is gone
entirely) no drop-blocking of their own. One partition, one file, archived at the exact moment you
choose to call it -- the simplest mental model on this page. The cost: the vacuum-horizon hold
spans the whole read-and-upload of that partition, for as long as whatever transaction you call it
in stays open, and nothing prevents `pgpm.retire()`/`pgpm.retain()` from dropping a partition you
have not archived yet -- that ordering is entirely your own script's responsibility.

## `config.archive_fn`: automatic, bounded, drop-gated

[Chunked, cross-partition Parquet archival](chunked-parquet.md) is the built-in strategy behind
`pgpm.config.archive_fn` (see
[`docs/retention-write-block-and-merge.md`](../../docs/retention-write-block-and-merge.md), #242):
an already-write-blocked child is archived in byte-budget-sized chunks, one per `maintain()` tick,
recorded in `pgpm.archive_ledger`; `pgpm.retire()` checks `pgpm._archive_fully_covered` directly and
will not drop a child until the last chunk has landed. There is no separate gate function to
register and no drop-trigger choice to make -- write-blocking and archive-coverage are both
`pgpm_core`'s own drop precondition, unconditionally, for every managed table. Setting
`config.archive_fn` to `pgpm.archive_to_s3_ndjson` or `pgpm.archive_to_s3_parquet` is the whole
installation; see [the reference](../../docs/reference.md#archive-strategy-contract) for the full
contract.

## Two knobs that apply either way

- **Format**: NDJSON (`pgpm.archive_to_s3_ndjson`/`archive.to_s3`) or Parquet
  (`pgpm.archive_to_s3_parquet`/`archive.to_s3_parquet`). NDJSON is universal and
  human-readable, parseable by anything that reads JSON lines, and round-trips any column type.
  Parquet is columnar and directly queryable by DuckDB, Athena, Redshift Spectrum, Spark, Trino,
  and Snowflake with no conversion step, at the cost of being a from-scratch, zero-dependency
  writer with real limits (six types, no dictionary encoding, no statistics, one row group -- see
  [Archive partitions to S3](to-s3.md#honest-limits-for-the-parquet-variant)).
- **Compression**: GZIP on or off, for either format. The compressor (`archive._pq_gzip_compress`)
  takes any `bytea` and returns a valid gzip container -- it has nothing to do with Parquet
  specifically. `archive.config.compress` (one column, read by every function on both pages) picks
  it per table; it is not free (PR #205 measured real compression time from ~50ms/MB on highly
  compressible data up to ~2.6s/MB on near-incompressible data), and that time counts against
  whichever vacuum-horizon hold applies to the strategy in use.

## What's built, what's a gap

- The synchronous functions: NDJSON built (single-PUT and multipart, no compression); Parquet
  built (single-PUT, GZIP-capable) -- multipart Parquet is an open question, not a clear gap
  (#211).
- `config.archive_fn`'s built-in strategy: NDJSON and Parquet both built, each single-shot per
  chunk (Parquet cannot use an internal-commit technique at all, a structural fact about the
  format, #211). Compression works on either format.
- The Parquet chunking path's own CI does not independently re-verify an uploaded object against
  pyarrow/DuckDB the way the underlying encoder's original verification did -- see [Chunked,
  cross-partition Parquet archival's own honest limits](chunked-parquet.md#verified-end-to-end)
  for the specific gap.

## Choosing among them

- You want the drop itself to wait on archiving, automatically, with no discipline required of
  whoever calls `retire()`/`retain()`: **`config.archive_fn`**. Pick
  `pgpm.archive_to_s3_ndjson` for the simplest consumer story, or `pgpm.archive_to_s3_parquet` if
  you want the archive directly queryable by an analytics engine without a conversion step.
- Partitions are small enough (or your vacuum tolerance is loose enough) that holding the horizon
  for one partition's read-and-upload doesn't worry you, and you are comfortable keeping the
  archive-then-drop ordering as your own script's discipline: **the synchronous functions**. Same
  format choice applies.
- Partition sizes are large or uneven, and you want file size to be a deliberate operational
  choice rather than emergent: **`config.archive_fn`** either way -- its chunking is bounded by
  `config.archive_byte_budget`, not by whatever a partition happens to grow to.

Whichever you pick, compression is close to free to turn on wherever it's wired (it costs real,
non-trivial time -- see [Chunked, cross-partition Parquet archival's honest
limits](chunked-parquet.md#honest-limits) for measured numbers -- but no design tradeoff beyond
that), and multipart transport only matters for the synchronous functions, and only really helps
NDJSON.

## Positioning

This page is a map, not a third mechanism. `archive.to_s3`, `archive.to_s3_parquet`, and
`config.archive_fn`'s built-in strategy all continue to work exactly as their own pages describe;
nothing here changes their behavior. Both paths share the same underlying encode/upload steps
(`archive._encode_upload_ndjson_single`/`_encode_upload_parquet`) and the same `archive.config`
connection settings (bucket/region/endpoint/prefix/vault key names/compress) -- there is no second,
independently configured surface to keep in sync.
