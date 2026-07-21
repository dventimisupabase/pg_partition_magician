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
boolean, and a table mixing `NOT NULL` and nullable columns together.

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

All 20 cases pass against a live PG17 container as of this writing.
