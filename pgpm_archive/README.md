# pgpm_archive

Archive a `pg_partition_magician`-managed table's aged partitions to S3 (or any S3-compatible
store) before `pgpm.retain()` drops them.

## Why this lives apart from `pg_partition_magician` core

The [root project](../README.md) manages a partition's *lifecycle* -- when it's created, when it's
retired. What happens to a partition's data on its way out is a separate concern: this add-on
supplies the transport (S3 signing, encoding, credentials), while `pgpm_core` itself owns the
drop precondition (write-blocked and archive-covered) that makes archiving-before-drop safe.
Nothing here is required for ordinary partitioning, and `pgpm_core` has zero dependency on this
schema.

## Install

On top of `pgpm_core`:

```bash
psql "$DATABASE_URL" -f pgpm_core/install.sql
psql "$DATABASE_URL" -f pgpm_archive/install.sql
```

Then configure the table's connection settings and set its archive strategy:

```sql
insert into archive.config (parent_table, bucket, region) values
  ('public.events'::regclass, 'my-archive-bucket', 'us-east-1');

update pgpm.config set archive_fn = 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure
  where parent_table = 'public.events'::regclass;   -- or pgpm.archive_to_s3_parquet
```

That is the whole installation: no gate to register, no separate schedule. `pgpm.maintain()` (on
the pg_cron path, `pgpm.maintain_all()`) archives each eligible child in bounded, byte-budget-sized
chunks on its own schedule, and `pgpm.retire()` will not drop a partition until archiving has
actually caught up with it (`docs/retention-write-block-and-merge.md`, #242, in the root project).

`archive.config`'s `vault_key_id`/`vault_secret` columns (defaults:
`s3_archive_access_key_id`/`s3_archive_secret_access_key`) name the two
[Vault](https://supabase.com/docs/guides/database/vault) secrets holding your S3 credentials --
create those once, as a privileged role, before the first archive attempt:

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

## Two architectures, and how to pick

- **`config.archive_fn`** (`pgpm.archive_to_s3_ndjson` / `pgpm.archive_to_s3_parquet`): the normal
  way to use this module. `pgpm.maintain()` drives byte-budget-sized chunks automatically, ahead of
  every drop, ledgered in `pgpm.archive_ledger`; `retire()`'s own drop precondition waits for full
  coverage. No registration, no schedule, no gate to wire up yourself.
- **The synchronous functions** (`archive.to_s3` / `archive.to_s3_parquet`): called directly, by
  you, whenever you decide to archive a partition -- no ledger, no automatic scheduling, and
  nothing tying the call to a drop. Simplest mental model; holds the vacuum horizon for the whole
  read-and-upload, and the archive-then-drop ordering is entirely your own script's discipline to
  keep.

Read **[`docs/strategies-overview.md`](docs/strategies-overview.md) first** -- it's the map across
both and the fastest way to land on a configuration. Then, whichever fits:

- **[`docs/to-s3.md`](docs/to-s3.md)**: the synchronous functions, worked end-to-end (SigV4
  signing, Vault credentials, the multipart variant for larger partitions, a Parquet variant).
- **[`docs/chunked-parquet.md`](docs/chunked-parquet.md)**: the byte-budget strategy behind
  `config.archive_fn` -- decouples file size from partition size entirely, so the horizon-hold
  bound is a deliberate choice instead of an emergent one, and the Parquet range encoder both
  paths share.

## Testing

```bash
./test.sh archive
```

Brings up a MinIO service and a `pgsql-http`-enabled PostgreSQL 17 image (see the root
[`ONBOARDING.md`](../ONBOARDING.md) for the full harness) and runs `tests/archive/db/*.sql`
against it.
