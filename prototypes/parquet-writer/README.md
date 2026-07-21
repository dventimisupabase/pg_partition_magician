# Minimal-viable Parquet writer (prototype)

Hand-rolled Parquet writer in PL/pgSQL, zero extension dependencies (no
pg_parquet, pg_duckdb, pg_lake, or pg_mooncake). Prototype for
[pg_partition_magician#199](https://github.com/dventimisupabase/pg_partition_magician/issues/199);
not shipped code, not wired into pgpm_core.

## Scope

- One row group, one uncompressed PLAIN-encoded data page per column.
- `NOT NULL` columns only: no definition levels, no nulls. `pq.to_parquet()`
  raises loudly on any nullable column rather than silently emitting wrong
  data.
- Types: `int4`, `int8`, `float8`, `boolean`, `text` (UTF8), `timestamp[tz]`
  (`TIMESTAMP_MICROS`, via `extract(epoch from ...)`, sidestepping any need to
  know Postgres's internal 2000-01-01 epoch).
- Field IDs and enum values are taken directly from the canonical
  `apache/parquet-format` `parquet.thrift`, not from memory.

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
3. PLAIN encoders per Parquet physical type, including boolean bit-packing.
4. Struct builders for `SchemaElement`, `DataPageHeader`, `PageHeader`,
   `ColumnMetaData`, `ColumnChunk`, `RowGroup`, `FileMetaData`.
5. `pq.to_parquet(regclass) returns bytea`: introspects the relation's
   columns via `pg_attribute`, refuses nullable/unsupported columns, pulls
   each column via `array_agg(col::type order by ctid)` (the explicit
   `order by ctid` keeps every column's array aligned to the same row order,
   since two separate `array_agg` calls have no order guarantee otherwise),
   and assembles the final file.

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
multi-byte varints in the footer metadata), and refusal of nullable columns.

```bash
docker-compose --profile pg17 up -d
python3 -m venv .venv && ./.venv/bin/pip install pyarrow psycopg2-binary duckdb pandas numpy
./.venv/bin/python verify.py
```

All 13 cases pass against a live PG17 container as of this writing.
