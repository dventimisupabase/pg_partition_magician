# Minimal-viable Parquet writer (prototype)

Hand-rolled Parquet writer in PL/pgSQL, zero extension dependencies (no
pg_parquet, pg_duckdb, pg_lake, or pg_mooncake). Prototype for
[pg_partition_magician#199](https://github.com/dventimisupabase/pg_partition_magician/issues/199);
not shipped code, not wired into pgpm_core.

**This encoder is now also wired into a real `pre_drop` hook**, verified
end-to-end through `pgpm.retire()` against MinIO: see
[`docs/archive-to-s3.md`](../../docs/archive-to-s3.md#a-columnar-variant-parquet-instead-of-ndjson).
That version renames the `pq.*` functions here into the `archive` schema and
adds a bytea-native SigV4 signer (`archive.s3_signed_request_bytea`), since
the existing text-based signer's `convert_to(payload, 'UTF8')` call rejects
a real Parquet payload's binary content. This directory stays as the
standalone spike the docs version grew from.

## Scope

- One row group, one uncompressed PLAIN-encoded data page per column.
- Nullable columns are supported. A flat, non-nested schema only ever needs
  `max_definition_level = 1`, so a nullable column's definition levels are a
  single bit-packed run (a present/null bitmap, per Data page v1's
  RLE/bit-packed-hybrid encoding), 4-byte-length-prefixed ahead of the
  values, which contain only the non-null rows. `pq.to_parquet()` still
  raises loudly on any genuinely unsupported column type rather than
  silently emitting wrong data.
- Types: `int4`, `int8`, `float8`, `boolean`, `text` (UTF8), `timestamp[tz]`
  (`TIMESTAMP_MICROS`, via `extract(epoch from ...)`, sidestepping any need to
  know Postgres's internal 2000-01-01 epoch).
- Field IDs, encodings, and enum values are taken directly from the canonical
  `apache/parquet-format` `parquet.thrift` and `Encodings.md`, not from
  memory -- worth flagging specifically: the level encoding's header is a
  *plain* ULEB128 varint, unrelated to the zigzag varint the Thrift
  compact-protocol footer uses everywhere else in this file, easy to
  conflate since both are just called "varint".

Everything else (dictionary encoding, compression, multiple row groups,
statistics, nested/repeated schemas) is out of scope. So is Iceberg: it needs
a second binary format (Avro, for manifests) plus a catalog commit protocol,
neither of which reduces to a single PL/pgSQL function.

## The cross-partition range variant

`pq.to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text)`
reads a `[p_lo, p_hi)` range of a control column off a relation -- typically a
partitioned parent -- instead of one whole relation, relying on Postgres's own
partition pruning to span whichever children the range touches. It exists for
[the chunked, cross-partition archival design](../../archive-chunked-parquet-design.md):
decoupling a Parquet file's boundaries from partition boundaries means a file
can cover part of a partition, one whole partition, or several, so the encoder
needs a query shape that isn't "select every row of this one child."

Two things `pq.to_parquet` doesn't need come along with that:

- **A real key, not `ctid`.** `ctid` identifies a row's physical location within
  *one* heap; it isn't comparable once a range spans more than one child's heap.
  `pq._key_columns()` discovers a resumable-read key the same way
  `pgpm.regrain_step` already does (`pgpm_core/install.sql`): prefer a PRIMARY
  KEY, else a predicate/expression-free UNIQUE CONSTRAINT, never a bare UNIQUE
  INDEX unbacked by a constraint. A genuinely keyless relation is refused
  outright, the same `'nokey'` contract `regrain()` already enforces -- an
  inherited limitation, not a new gap.
- **A composite sort, not just the control column.** A time-kind control column
  routinely repeats (duplicate timestamps are common), so ordering by it alone
  is not deterministic. The encoder orders by `(control column, key columns...)`
  instead, so every row's position is unique and reproducible -- a property a
  future chunk boundary needs (see the design note on the chunker's stopping
  rule; not built in this rung, only enabled by it).

`p_lo`/`p_hi` are literals already typed for the control column's actual SQL
type; a caller translating a pgpm native-grid value (e.g. for a `uuidv7`-kind
column, whose native grid is `timestamptz` but whose column type is `uuid`)
does that translation itself first, the same way `regrain_step` builds its own
`v_lo_lit`/`v_hi_lit` before it.

`verify_range.py` covers: a range spanning two and three children, a sub-range
confined to one child, five rows tied on the same control-column value ordered
correctly by the real key (not insertion order), the exclusive-`hi` boundary
landing exactly on both a data tie and a partition boundary simultaneously, an
empty range, a three-column composite key, the UNIQUE CONSTRAINT fallback (no
primary key present), a bare UNIQUE INDEX correctly refused, a genuinely
keyless table correctly refused, and an `EXPLAIN`-verified check that
partition pruning actually excludes untouched children rather than just being
assumed.

```bash
docker-compose --profile pg17 up -d
./.venv/bin/python verify_range.py
```

## GZIP compression

`pq.to_parquet(regclass, p_compress default false)` and `pq.to_parquet_range(..., p_compress
default false)` take an optional flag to GZIP-compress each column's page bytes instead of
writing them uncompressed. This is a real DEFLATE (RFC 1951) encoder written from scratch --
LZ77 matching plus fixed-Huffman entropy coding, not a call out to any compression library --
plus a CRC-32 (RFC 1952) trailer, all in PL/pgSQL with zero extension dependencies. Confirmed
empirically (not assumed) that Parquet's GZIP codec means the full RFC 1952 container (10-byte
header, deflate stream, CRC-32 + ISIZE trailer), by writing a real GZIP-compressed file with
pyarrow itself and checking the page bytes open with the `1f8b` gzip magic and read cleanly via
Python's stdlib `gzip` reader -- not the bare RFC 1950 zlib framing a different codec would use.

**LZ77 matching**, the part that actually earns compression ratio, needed two ideas to avoid
O(n^2) behavior without writing (and likely getting subtly wrong) a real hash-chain data
structure:

- **Candidate-finding as a SQL self-join, not a hand-rolled chain.** A rolling 3-byte hash per
  position, indexed, then `... JOIN LATERAL (SELECT ... ORDER BY pos DESC LIMIT 1) ...` to find
  the nearest prior position sharing that hash within the 32KB window. An earlier version used
  an unbounded `GROUP BY pos, MAX(candidate)`, which blew up to 35s on 170KB of *exactly the
  highly-repetitive input compression matters most for* (every position shares a hash with
  thousands of others); the `LATERAL ... LIMIT 1` form lets the planner use a backward
  index-only scan and stop at the first hit, regardless of how repetitive the data is.
- **Match-length extension via binary search, not a byte-by-byte loop.** `substr(data,a,k) =
  substr(data,b,k)` is a single native comparison regardless of `k`; bisecting on `k` finds the
  true match length in O(log match_length) comparisons instead of O(match_length).
- **Lazy evaluation, driven by the greedy parse.** Only look up a candidate at positions the
  parse actually visits -- a position consumed by a preceding match is never queried at all.
  For highly compressible input this cut lookups from ~1M to ~4,800 for a 1MB payload (parse
  time 4.3s -> 40ms); for near-incompressible input the reduction is smaller but still real
  (~2x). The first version of this used `EXECUTE format(...)` so the lookup query could take a
  table name parameter; that alone cost ~2.5x versus a plain hardcoded-table-name query, once
  isolated from a *second* confound (the correctness-verification reconstruction step has its
  own unrelated O(n^2) cost that was swamping the actual measurement) -- both had to be
  untangled before the real number was visible.

**Huffman/bit-packing** surfaced a third instance of the same general lesson (small per-call
overhead dominating simple work, once multiplied by enough calls): the length/distance code
lookups were originally separate PL/pgSQL functions with `OUT` parameters, invoked via `SELECT
... FROM f(...)` once per LZ77 match. That calling convention alone cost more than the entire
LZ77 tokenizer for a 1MB near-incompressible payload (~1.9s vs ~1.6s) -- more than the bit-level
work it was computing inputs for. Inlining those lookups as `CASE` expressions directly in the
hot loop, combined with merging a whole Huffman code into a wide accumulator via one shift+OR
(bit-reversing the code once per *token*, not once per output *bit* -- Huffman codes are
MSB-first on the wire, but the byte stream itself packs LSB-first, an easy inversion to make by
accident) took a 1MB near-incompressible payload from 4.56s to 2.64s.

Verified two ways for every case, matching the project's verification bar: the raw DEFLATE
stream via `zlib.decompress(data, wbits=-15)`, and the full GZIP container via stdlib `gzip`
(which verifies its own CRC-32 internally, a check with zero code in common with this encoder).
Then, separately, real Parquet files built end-to-end by `pq.to_parquet`/`to_parquet_range`
with `p_compress => true`, read back by both pyarrow (confirming `codec: GZIP`) and DuckDB, and
checked row-for-row against the live source table -- covering plain columns, nullable columns
(the definition-levels bitmap and the values are compressed together as one page), an empty
table, and a cross-partition range spanning two children.

## Layout

`parquet_writer.sql` implements, bottom-up:

1. Byte primitives: LEB128 varint, zigzag, big-endian-to-little-endian byte
   reversal (`pq._reverse_bytes`, wrapping Postgres's own `int4send`/
   `int8send`/`float8send` rather than hand-rolling two's-complement/IEEE754
   arithmetic).
2. A small Thrift compact-protocol encoder: field headers (short and long
   form), typed field writers (i32/i64/binary/struct), and list encoding
   (short and long form).
3. PLAIN encoders per Parquet physical type, including boolean bit-packing;
   `pq._definition_levels()`, the RLE/bit-packed-hybrid definition-levels
   encoder for nullable columns (the same LSB-first-per-byte packing as the
   boolean encoder, since bit_width=1 collapses to that shape).
4. Struct builders for `SchemaElement`, `DataPageHeader`, `PageHeader`,
   `ColumnMetaData`, `ColumnChunk`, `RowGroup`, `FileMetaData`.
   `SchemaElement`'s `repetition_type` is `REQUIRED` or `OPTIONAL` per
   column, driven by `attnotnull`.
5. `pq.to_parquet(regclass) returns bytea`: introspects the relation's
   columns via `pg_attribute`, refuses genuinely unsupported column types,
   pulls each column via `array_agg(col::type order by ctid)` (the explicit
   `order by ctid` keeps every column's array aligned to the same row order,
   since two separate `array_agg` calls have no order guarantee otherwise;
   `array_agg` preserves `NULL`s in position, so this is one pass either
   way), and assembles the final file.
6. A from-scratch DEFLATE/GZIP compressor (`pq._gzip_compress`, see "GZIP
   compression" below): LZ77 matching (SQL self-join for candidates, binary
   search for match length, lazy evaluation driven by the greedy parse) plus
   fixed-Huffman bit-packing and a CRC-32 trailer. Optional, via
   `p_compress` on `pq.to_parquet`/`to_parquet_range`.

## Verification

`verify.py` does not test anything "in Postgres": `pq.to_parquet()`'s only
job is to produce bytes, so the bytes are written to a temp file and read
back by two **independent** Parquet readers, pyarrow (Arrow's C++ reader)
and DuckDB (its own from-scratch reader), asserting value equality against
the same rows fetched directly from Postgres, not just "it opened without
error". Covers: int32/int64 boundaries (`INT32_MIN/MAX`, `INT64_MIN/MAX`),
float8 including infinities, boolean bit-packing across a byte boundary,
text (empty/unicode/long), the timestamptz-epoch conversion, mixed-type
rows, empty tables, a single row, 20 columns (forces the Thrift long-form
field/list header path), quoted/reserved-word identifiers, 500 rows (forces
multi-byte varints in the footer metadata), refusal of a genuinely
unsupported type, and a run of nullable-column cases: mixed nulls crossing
a definition-levels byte boundary, an all-null column, a nullable column
declared but with no actual nulls, an empty table with a nullable column,
`NULL` staying distinct from `''` in a nullable text column, a nullable
boolean, and a table mixing `NOT NULL` and nullable columns together. Plus
four `p_compress => true` cases: repetitive text (real LZ77 matches, checked
smaller than the uncompressed version and `codec: GZIP` via pyarrow),
nullable columns compressed, low-entropy hex text (near-worst-case for
LZ77 -- correctness under a bad ratio, not the ratio itself), and an empty
table.

Note on the DuckDB side of `read_with_both_readers()`: it fetches raw
tuples, not `.fetchdf()` (pandas). Pandas represents SQL `NULL` as `NaN`,
not `None`, which would make every null-column assertion below compare
`NaN != None` and fail (or silently pass) for the wrong reason -- caught
before writing the nullable-column tests, not after.

```bash
docker-compose --profile pg17 up -d
python3 -m venv .venv && ./.venv/bin/pip install pyarrow psycopg2-binary duckdb pandas numpy
./.venv/bin/python verify.py
```

All 24 cases pass against a live PG17 container as of this writing.
