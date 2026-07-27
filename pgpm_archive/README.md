# pgpm_archive

Archives a `pg_partition_magician`-managed table's aged partitions to S3 (or any S3-compatible
store) before `pgpm.retain()` drops them. Optional: `pgpm_core` has zero dependency on this
module.

## Install

```bash
psql "$DATABASE_URL" -f pgpm_core/install.sql
psql "$DATABASE_URL" -f pgpm_archive/install.sql
```

Store your S3 credentials in [Vault](https://supabase.com/docs/guides/database/vault), once, as a
privileged role (the caller needs `select` on `vault.decrypted_secrets` to read them back):

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

Then, per table, set connection settings and turn on automatic archiving:

```sql
select archive.configure('public.events', 'my-archive-bucket');   -- region/endpoint/prefix/etc. all default sanely
select pgpm.set_archive_fn('public.events',
  'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);   -- or archive_to_s3_ndjson
```

That's it: `pgpm.maintain()` now archives every eligible partition automatically, in bounded
chunks, and `pgpm.retire()` won't drop one until it's fully archived. `archive.configure`'s other
parameters (`p_region`, `p_endpoint` for S3-compatible stores like MinIO or Supabase Storage,
`p_prefix`, `p_compress`, etc.) all have sensible defaults -- pass only what you need to override.

## Automatic vs. manual

| | Automatic | Manual |
|---|---|---|
| Turn on | `pgpm.set_archive_fn(parent, fn)`, once | nothing to set up |
| Runs | every `pgpm.maintain()` tick, in bounded chunks | whenever you call it |
| Drop safety | `pgpm.retire()` waits until fully archived | your own script's responsibility |
| Call | -- | `archive.to_s3(parent, child, lo, hi)` / `archive.to_s3_parquet(...)` |

Automatic is the normal way to use this module. Manual exists for a one-off archive or a workflow
that doesn't want pgpm's own drop-gating; call it, then drop the partition however you like:

```sql
select archive.to_s3('public.events', 'events_p2024_01', '2024-01-01', '2024-02-01');
select pgpm.retire('public.events', 'events_p2024_01');
```

See the [reference](../docs/reference.md#archive-strategy-contract) for the full `archive_fn`
contract and the [guide](../docs/guide.md#archiving-before-a-drop) for the operator's view.

## NDJSON or Parquet

- **NDJSON** (`pgpm.archive_to_s3_ndjson` / `archive.to_s3`): universal, human-readable, round-trips
  any column type.
- **Parquet** (`pgpm.archive_to_s3_parquet` / `archive.to_s3_parquet`): columnar, directly queryable
  by DuckDB, Athena, Redshift Spectrum, Spark, Trino, and Snowflake with no conversion step -- a
  from-scratch, zero-dependency writer with real limits (see below).

GZIP compression applies to either format (`archive.config.compress`, off by default). It's not
free: real compression time runs from ~50ms/MB on compressible data up to ~2.6s/MB on
near-incompressible data.

## Limits

- **Parquet supports six types**: `int4`, `int8`, `float8`, `boolean`, `text`,
  `timestamp`/`timestamptz`. Anything else (arrays, JSON/JSONB, `numeric`, `uuid`, composite types)
  is refused; cast to a supported type in a view if you need one archived this way. One row group,
  no dictionary encoding, no statistics.
- **Payload size**: `archive.to_s3` (NDJSON) streams through S3 multipart in bounded memory once a
  partition exceeds one ~8MiB part, so it handles any size. `archive.to_s3_parquet` has no
  multipart path and would not benefit from one -- a Parquet file's footer needs every row group's
  byte offset, known only once the whole file is built, so the encoder already holds the entire
  file in memory (Postgres's ~1GB cap) before any upload starts. For a partition whose Parquet
  encoding would exceed that, use the automatic path instead: `config.archive_fn` chunks by a
  target byte budget (`config.archive_byte_budget`, default 8 MiB) that's independent of partition
  size, so no single upload ever needs to hold a whole large partition in memory.
- **On Supabase**: Storage enforces the project's upload size limit (default 50MB) on the S3
  protocol too, and `statement_timeout` is 2 minutes -- both apply to a single manual call. The
  automatic path's chunking keeps each upload well under both.

## Testing

```bash
./test.sh archive
```

Brings up a MinIO service and a `pgsql-http`-enabled PostgreSQL 17 image (see the root
[`ONBOARDING.md`](../ONBOARDING.md)) and runs `tests/archive/db/*.sql` against it, then
`scripts/verify_parquet.py`/`verify_parquet_range.py` (independent-reader pyarrow + DuckDB
verification) against the same instance.
