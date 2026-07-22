# pgpm_archive

Archive a `pg_partition_magician`-managed table's aged partitions to S3 (or any S3-compatible
store) before `pgpm.retain()` drops them.

## Why this lives apart from `pg_partition_magician` core

The [root project](../README.md) manages a partition's *lifecycle* -- when it's created, when it's
retired. What happens to a partition's data on its way out is a separate concern, and this add-on
answers it: nothing here is required for ordinary partitioning, `pgpm_core` has zero dependency on
this schema, and it is **not referenced from the root `README.md`** on purpose. It started as
worked examples embedded in markdown (a `pre_drop` hook pattern, a paced worker with a ledger), and
later graduated into this installable module; it may move to its own repo eventually. Until then it
lives here, one directory, self-contained.

## Install

On top of `pgpm_core`:

```bash
psql "$DATABASE_URL" -f pgpm_core/install.sql
psql "$DATABASE_URL" -f pgpm_archive/install.sql
```

Then configure one row per managed table in `archive.config` and register the gate hook:

```sql
insert into archive.config (parent_table, bucket, region, endpoint, prefix, boundary_rule, drop_trigger, format, compress)
values ('public.events', 'my-archive-bucket', 'us-east-1', null, 'events/',
        'partition_aligned',   -- or 'byte_budget'
        'self_driving',        -- or 'gate_only'
        'ndjson_commits',      -- or 'ndjson_single' / 'parquet'
        false);

select pgpm.hook_register('public.events', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select cron.schedule('pgpm-archiver', '* * * * *', 'call archive.tick()');   -- one job, every configured table
```

`archive.config`'s `vault_key_id`/`vault_secret` columns (defaults:
`s3_archive_access_key_id`/`s3_archive_secret_access_key`) name the two
[Vault](https://supabase.com/docs/guides/database/vault) secrets holding your S3 credentials --
create those once, as a privileged role, before the first `archive.tick()`:

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

## Two architectures, and how to pick

- **The synchronous hook** (`archive.to_s3` / `archive.to_s3_parquet`): archives a partition
  inline, inside `retain()`'s own drop transaction. Simplest mental model; holds the vacuum
  horizon for the whole read-and-upload.
- **The paced worker** (everything else -- `archive.tick()`/`archive.run_all()`): an
  independently-paced procedure that archives ahead of any drop, records what it's archived in a
  ledger, and commits between chunks of work to bound the vacuum-horizon hold. Two independent
  knobs (`boundary_rule`: partition-aligned or byte-budget-aligned; `drop_trigger`: who actually
  calls `retire()`) plus a format/compression choice on top.

Read **[`docs/strategies-overview.md`](docs/strategies-overview.md) first** -- it's the map across
all of this and the fastest way to land on a configuration. Then, whichever architecture fits:

- **[`docs/to-s3.md`](docs/to-s3.md)**: the synchronous hook, worked end-to-end (SigV4 signing,
  Vault credentials, the multipart variant for larger partitions, a Parquet variant).
- **[`docs/assistant.md`](docs/assistant.md)**: the paced worker's partition-aligned rule --
  bounded vacuum-horizon holds via per-part commits, assistant-owned drops via `pgpm.retire`.
- **[`docs/chunked-parquet.md`](docs/chunked-parquet.md)**: the paced worker's byte-budget-aligned
  rule -- decouples file size from partition size entirely, so the horizon-hold bound is a
  deliberate choice instead of an emergent one.

Each page keeps its own hand-rolled SQL and verified names alongside the module's -- see
`docs/strategies-overview.md`'s name-mapping table if you're cross-referencing both.

## Testing

```bash
./test.sh archive
```

Brings up a MinIO service and a `pgsql-http`-enabled PostgreSQL 17 image (see the root
[`ONBOARDING.md`](../ONBOARDING.md) for the full harness), and runs `tests/archive/db/*.sql`
against it, one disposable database per file.
