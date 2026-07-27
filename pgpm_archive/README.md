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
actually caught up with it.

`archive.config`'s `vault_key_id`/`vault_secret` columns (defaults:
`s3_archive_access_key_id`/`s3_archive_secret_access_key`) name the two
[Vault](https://supabase.com/docs/guides/database/vault) secrets holding your S3 credentials --
create those once, as a privileged role, before the first archive attempt:

```sql
select vault.create_secret('AKIAIOSFODNN7EXAMPLE',                     's3_archive_access_key_id');
select vault.create_secret('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 's3_archive_secret_access_key');
```

The role that calls the archive functions needs `select` on `vault.decrypted_secrets` to read them
back.

## Choosing an archival strategy

Two ways to get a partition's rows to S3 before `pgpm.retain()`/`pgpm.retire()` drops it, one call
away from each other in effort but structurally different in what they guarantee:

- **The synchronous functions** (`archive.to_s3`, `archive.to_s3_parquet`): called directly, by
  you, whenever you decide to archive a partition. Simplest mental model, but nothing ties the
  call to a drop -- archiving first is entirely your own script's discipline to keep.
- **`pgpm.config.archive_fn`** (`pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet`, the
  byte-budget chunked strategy this module ships): set once per table, and `pgpm.maintain()` drives
  it automatically, ahead of every drop, in bounded chunks. `pgpm.retire()` will not drop a
  partition until this strategy reports it fully covered -- no registration, no separate schedule,
  no gate to wire up yourself.

### The synchronous functions

`archive.to_s3`/`archive.to_s3_parquet` read and upload one partition in a single call, whenever
you call them -- no ledger, no automatic scheduling, and no drop-blocking of their own. One
partition, one file, archived at the exact moment you choose to call it -- the simplest mental
model here. The cost: the vacuum-horizon hold spans the whole read-and-upload of that partition,
for as long as whatever transaction you call it in stays open, and nothing prevents
`pgpm.retire()`/`pgpm.retain()` from dropping a partition you have not archived yet -- that
ordering is entirely your own script's responsibility. Described in full below.

### `config.archive_fn`: automatic, bounded, drop-gated

An already-write-blocked child is archived in byte-budget-sized chunks, one per `maintain()` tick,
recorded in `pgpm.archive_ledger`; `pgpm.retire()` checks `pgpm._archive_fully_covered` directly and
will not drop a child until the last chunk has landed. There is no separate gate function to
register and no drop-trigger choice to make -- write-blocking and archive-coverage are both
`pgpm_core`'s own drop precondition, unconditionally, for every managed table. Setting
`config.archive_fn` to `pgpm.archive_to_s3_ndjson` or `pgpm.archive_to_s3_parquet` is the whole
installation; see [the reference](../docs/reference.md#archive-strategy-contract) for the full
contract, and [chunked, cross-partition Parquet
archival](#chunked-cross-partition-parquet-archival-bounding-the-horizon-by-file-size) below for how
it's built.

### Two knobs that apply either way

- **Format**: NDJSON (`pgpm.archive_to_s3_ndjson`/`archive.to_s3`) or Parquet
  (`pgpm.archive_to_s3_parquet`/`archive.to_s3_parquet`). NDJSON is universal and human-readable,
  parseable by anything that reads JSON lines, and round-trips any column type. Parquet is columnar
  and directly queryable by DuckDB, Athena, Redshift Spectrum, Spark, Trino, and Snowflake with no
  conversion step, at the cost of being a from-scratch, zero-dependency writer with real limits (six
  types, no dictionary encoding, no statistics, one row group -- see [honest limits, for the Parquet
  variant](#honest-limits-for-the-parquet-variant)).
- **Compression**: GZIP on or off, for either format. The compressor
  (`archive._pq_gzip_compress_dynamic`, a real per-block Huffman code, not a fixed table; the older
  `archive._pq_gzip_compress` stays defined and directly callable as a simpler, slightly cheaper
  rung, but every call site this module drives on its own uses the dynamic variant) takes any
  `bytea` and returns a valid gzip container -- it has nothing to do with Parquet specifically.
  `archive.config.compress` (one column, read by every function) picks it per table; it is not free
  (measured real compression time from ~50ms/MB on highly compressible data up to ~2.6s/MB on
  near-incompressible data for the fixed-Huffman variant -- dynamic Huffman costs somewhat more
  building the per-block code), and that time counts against whichever vacuum-horizon hold applies
  to the strategy in use.

### What's built, what's a gap

- The synchronous functions: NDJSON built (single-PUT and multipart, no compression); Parquet built
  (single-PUT, GZIP-capable) -- multipart Parquet is not a gap, it just would not help (see [honest
  limits, for the Parquet variant](#honest-limits-for-the-parquet-variant)).
- `config.archive_fn`'s built-in strategy: NDJSON and Parquet both built, each single-shot per chunk
  (Parquet cannot use an internal-commit technique at all, a structural fact about the format).
  Compression works on either format.
- The Parquet chunking path's own CI does not independently re-verify an uploaded object against
  pyarrow/DuckDB the way the underlying encoder's original verification did -- see [chunked Parquet's
  own verified-end-to-end section](#verified-end-to-end) for the specific gap.

### Choosing among them

- You want the drop itself to wait on archiving, automatically, with no discipline required of
  whoever calls `retire()`/`retain()`: **`config.archive_fn`**. Pick `pgpm.archive_to_s3_ndjson` for
  the simplest consumer story, or `pgpm.archive_to_s3_parquet` if you want the archive directly
  queryable by an analytics engine without a conversion step.
- Partitions are small enough (or your vacuum tolerance is loose enough) that holding the horizon
  for one partition's read-and-upload doesn't worry you, and you are comfortable keeping the
  archive-then-drop ordering as your own script's discipline: **the synchronous functions**. Same
  format choice applies.
- Partition sizes are large or uneven, and you want file size to be a deliberate operational choice
  rather than emergent: **`config.archive_fn`** either way -- its chunking is bounded by
  `config.archive_byte_budget`, not by whatever a partition happens to grow to.

Whichever you pick, compression is close to free to turn on wherever it's wired (it costs real,
non-trivial time, but no design tradeoff beyond that), and multipart transport only matters for the
synchronous functions, and only really helps NDJSON.

## The synchronous functions: `archive.to_s3` / `archive.to_s3_parquet`

A plain function, called directly, that reads and uploads one partition in a single call -- no
ledger, no automatic scheduling, and no drop-blocking of its own. Install `pgpm_archive/install.sql`
(covered above) and call it yourself before dropping a partition another way:

```sql
select archive.to_s3('public.events'::regclass, 'events_p2024_01', '2024-01-01', '2024-02-01');
select pgpm.retire('public.events'::regclass, 'events_p2024_01');   -- or however you drop it
```

That ordering discipline is entirely yours to keep: nothing prevents `retire()`/`retain()` from
dropping a partition you haven't archived yet, since (unlike `config.archive_fn`, above) this
function is not wired into any drop precondition.

**The moving parts**: the [`http` extension](https://github.com/pramsey/pgsql-http) makes the PUT
(synchronous libcurl in the calling backend, so the real HTTP status comes back in the same call --
`pg_net` cannot do this job, it supports no PUT and is asynchronous by design); `pgcrypto` provides
`digest`/`hmac` for AWS Signature Version 4, translated straight from the published recipe; and
Vault holds the credentials encrypted at rest, decrypted only at call time (covered in
[Install](#install) above).

Everything lives in a dedicated `archive` schema, not `public`: on Supabase, `public` is typically
exposed through the Data API (PostgreSQL grants `EXECUTE` to `PUBLIC` on new functions by default),
and PostgREST only serves schemas you explicitly expose. The full implementation is `archive.to_s3`
in [`install.sql`](install.sql); a retried upload is naturally safe (a PUT to the same key
overwrites, so a call that succeeded on S3 but failed to report never duplicates or corrupts the
archive).

**When S3 is down**: the function raises (curl's or S3's error, verbatim) and returns without doing
anything else -- no partition is dropped as a side effect of calling it. Handling the failure
(retry, alert, skip this partition until next time) is entirely the caller's own script's job.

**Verified twice, end-to-end, driven by real HTTP calls each time**: against MinIO's full AWS
Signature Version 4 enforcement (a 50,000-row partition archived, then dropped via a separate
`retire()` call; an endpoint outage causing the archive call itself to raise, surfaced to the
caller directly), and against a live Supabase project archiving to [Supabase Storage's
S3-compatible endpoint](https://supabase.com/docs/guides/storage/s3/authentication) (same shape,
plus a real S3 rejection: a PUT to a missing bucket came back HTTP 404 with the S3 XML error raised
verbatim).

### Honest limits

- **The payload is one in-memory value.** `archive.to_s3` assembles the whole partition as one
  `text` value (NDJSON) and one `http()` call sends it: no streaming. Postgres caps a `text` value
  at 1GB, and the practical ceiling (memory, timeout) is well below that. This fits a fine
  `partition_step` whose partitions are tens-to-hundreds of MB; see [the multipart
  variant](#the-multipart-variant) below for any size, in bounded memory.
- **The upload runs inside whatever transaction the caller runs it in.** Nothing here opens or
  manages a transaction of its own -- call it standalone or as part of a larger script, and the
  vacuum-horizon hold lasts exactly as long as that transaction does.
- **Watch the timeout.** The `http` extension defaults to 5 seconds per request; `install.sql`
  sizes it up for a partition-scale upload via `http_set_curlopt('CURLOPT_TIMEOUT_MS', ...)`. A
  call that times out raises like any other failure.
- **Two Supabase ceilings, discovered during live verification.** Supabase Storage enforces the
  project's upload file size limit (**default 50MB**) on the S3 protocol too, per whole object,
  multipart included: an archive bigger than the limit fails with `HTTP 413` / `EntityTooLarge`
  until you raise the limit in the Dashboard under **Storage -> Files -> Settings**. And
  `statement_timeout` is **2 minutes** there (a server configuration-file setting, so it applies
  over the pooler and direct connections alike): the whole upload runs inside one statement, so
  that's this function's wall-clock ceiling on Supabase; override with a session `set
  statement_timeout = ...` if a partition legitimately needs longer, or use `config.archive_fn`'s
  byte-budget chunking instead, whose per-chunk calls each only need to fit one chunk in the
  window.

### The multipart variant

`archive.to_s3` itself streams through S3 multipart once a partition exceeds one ~8MiB part: it
keyset-paginates on the control column, ships each accumulation as a part, and completes the
upload at the end, holding **at most one part in memory**. Small and empty partitions
short-circuit to a plain single PUT. The full implementation (`archive.s3_url_encode`,
`archive.s3_signed_request`, `archive.to_s3`) is in [`install.sql`](install.sql).

What changes, honestly:

- **Memory is bounded; transaction duration is not.** Multipart fixes the 1GB `text` cap and the
  memory ceiling, but the whole upload still runs inside whichever transaction the caller runs it
  in. S3's own limits (10,000 parts) put the protocol ceiling around 80GB at this part size; the
  polite ceiling is far lower and set by how long you are willing to hold a transaction open. To
  bound that hold to a chosen chunk size instead, entirely in-database, use `config.archive_fn`'s
  byte-budget chunking; past that, hand the work to an external worker with a real AWS SDK.
- **A failed upload is aborted, not leaked.** An incomplete multipart upload is invisible in
  listings but accrues storage. On any failure after initiation, the function sends
  `AbortMultipartUpload` before re-raising. Belt and braces: also set a bucket lifecycle rule
  (`AbortIncompleteMultipartUpload`) for the day even the abort cannot reach S3.
- **The retry is still naturally safe.** Each retry is a fresh multipart upload under the same key;
  completion is atomic on S3's side, so a reader of the bucket never sees a half-written object.
- **`CompleteMultipartUpload` can fail inside an HTTP 200.** S3's one famous quirk: the complete
  call can return status 200 with an `<Error>` XML body, so the function checks both.

Verified against both MinIO and a live Supabase project archiving to Supabase Storage's
S3-compatible endpoint, same scenario on each: ~26MiB partitions archived as 3-part multipart
uploads (ETags carrying the `-3` part count) with every row account-checked across part boundaries
(150,000 contiguous ids per object, no lost or doubled line at any seam); an empty partition taking
the single-PUT fast path (bare-MD5 ETag); a simulated network failure during part 2 raising with
the abort confirmed on the store (`ListMultipartUploads` showing zero incomplete uploads left
behind); and the retried partition re-archiving completely on the next call. The two stores
returned **identical composite ETags** for the same partitions: the part boundaries are
deterministic, so the per-part MD5s match wherever the object lands.

### The Parquet variant

`archive.to_s3_parquet` writes the same shape of archive as `archive.to_s3`, but as Parquet instead
of NDJSON: directly queryable by DuckDB, Athena, Redshift Spectrum, Spark, Trino, and Snowflake
with no separate conversion step, at the cost of a from-scratch, zero-dependency writer (no
in-database extension on Supabase emits Parquet). It hand-rolls a Parquet file, Thrift
compact-protocol footer and all, in the same PL/pgSQL-plus-`pgcrypto`-plus-`http` toolbox as the
functions above.

```sql
select archive.to_s3_parquet('public.events'::regclass, 'events_p2024_01', '2024-01-01', '2024-02-01');
select pgpm.retire('public.events'::regclass, 'events_p2024_01');
```

**Scope, deliberately narrow.** One row group, one PLAIN-encoded data page per column, and six
types: `int4`, `int8`, `float8`, `boolean`, `text` (UTF8), and `timestamp`/`timestamptz`. Nullable
columns are supported (a flat schema only ever needs `max_definition_level = 1`, so a nullable
column's definition levels are a single bit-packed run). GZIP compression (RFC 1952, wrapping a
from-scratch DEFLATE encoder with a real per-block Huffman code, `archive._pq_gzip_compress_dynamic`)
is on by default. The full implementation (schema/row-group/column-chunk building, the DEFLATE/GZIP
encoder, `archive.to_s3_parquet` itself) is in [`install.sql`](install.sql).

**This holds the vacuum horizon like `archive.to_s3` above, not like a chunked strategy.** The
encoder reads every column of a partition in one pass, with no `COMMIT` in between (each column's
array has to come from the same snapshot as every other column's), so one in-memory value, one
upload -- no attempt is made here to bound the hold by chunking. See [chunked, cross-partition
Parquet
archival](#chunked-cross-partition-parquet-archival-bounding-the-horizon-by-file-size) below for
the strategy that does bound the hold, by choosing file boundaries independent of partition
boundaries entirely.

**Verified end-to-end**, driven against a live `http`-extension Postgres instance and MinIO: a real
partition (`transmute`d, `obtain`ed, 50 real rows) archived by a direct call, then dropped by a
separate `pgpm.retain()` call, with the object fetched back from MinIO and read by both pyarrow and
DuckDB (agreeing) matching the source rows exactly; a real failure (broken endpoint) raising the S3
error verbatim, with the partition left untouched; self-repair by calling again once the endpoint
was fixed; and GZIP on, through the same real path, with pyarrow and DuckDB again agreeing after
decompression. See `tests/archive/db/04_parquet_and_sync_archive_test.sql` for this exact shape
exercised as part of this project's own CI.

#### Honest limits, for the Parquet variant

- **Same ceiling as the single-PUT function, not the multipart one -- and multipart would not
  actually raise it (issue #211).** The payload is one in-memory `bytea` (Postgres's ~1GB cap);
  nothing here streams. Chunking the *already-built* Parquet `bytea` into fixed-size byte ranges
  for a multipart upload is mechanically straightforward, but it would not buy anything: the
  encoder already has to hold the whole file as one `bytea` before any network call happens, so a
  partition whose Parquet encoding would exceed the cap fails during *encoding*, before transport
  is ever reached. The real fix for a Parquet file too big to hold comfortably in memory is [the
  byte-budget chunked
  strategy](#chunked-cross-partition-parquet-archival-bounding-the-horizon-by-file-size), which
  sidesteps the problem by choosing smaller file boundaries instead of trying to stream-multipart
  one giant file.
- **Nullable columns supported, but only single-level (no nesting).** A nested/repeated schema
  would need more than this rung builds.
- **Six types.** Anything else (arrays, JSON/JSONB, `numeric`, composite types, `uuid`) is refused
  loudly by `archive._pq_to_parquet` rather than silently coerced; cast to a supported type in a
  view over the child, or extend the encoder, if you need one of these archived this way.
- **One row group, no dictionary encoding, no statistics.** All legal Parquet either way, all
  readable by every reader tested, none of it as compact as a tuned writer's dictionary-encoded,
  statistics-bearing output would be. This is the minimal-viable rung, not the ambitious one.
- **This function's horizon-hold is bounded by partition size, which is emergent, not by a chosen
  file size.** If partitions grow large enough (or unevenly enough) that this matters, see
  [chunked, cross-partition Parquet
  archival](#chunked-cross-partition-parquet-archival-bounding-the-horizon-by-file-size), which
  decouples Parquet file boundaries from partition boundaries entirely so the hold is bounded by a
  target file size instead.

## Chunked, cross-partition Parquet archival: bounding the horizon by file size

The byte-budget strategy behind `pgpm.config.archive_fn`: instead of archiving one partition into
one file, this decouples Parquet (or NDJSON) files from partition boundaries entirely, so a file's
size (and therefore its vacuum-horizon hold) is a deliberate, bounded choice, never an emergent
consequence of how big a partition happened to grow. It reuses [the Parquet
variant](#the-parquet-variant)'s encoder and the bytea-native SigV4 signer described above rather
than duplicating them.

`pgpm_core` itself drives this chunked archiving as part of `pgpm.maintain()`, ahead of every drop,
and `pgpm.retire()` will not drop a partition until its own coverage check
(`pgpm._archive_fully_covered`) says archiving has actually caught up -- no separate gate function
to register, no drop-trigger choice to make. Setting `pgpm.config.archive_fn` to
`pgpm.archive_to_s3_parquet` or `pgpm.archive_to_s3_ndjson` rides this mechanism directly; see [the
reference](../docs/reference.md#archive-strategy-contract) for the full contract and [the
guide](../docs/guide.md#archiving-before-a-drop) for the operator's view.

### Why partition size is the wrong unit to bound

The single-PUT Parquet function above bounds its vacuum-horizon hold in terms of *partitions* --
one whole partition's read+upload. That is fine as long as a partition's size is itself bounded,
but under time-cut partitioning, partition size is emergent -- ingest rate x row width x interval
-- not something the partitioning DDL controls at all. A busy month sitting next to a quiet one
means some partitions are ten times the size of their neighbors, and the function's horizon-hold
grows in lockstep with whichever partition happens to be up for archiving.

Parquet's footer needs every row group's byte offset known before it is written, which sounds like
a per-*file* constraint tied to a partition -- but it is really just a constraint on **whatever
range of rows becomes one file**, and nothing requires that range to line up with a partition
boundary. Once a file's size is chosen independently of the partitioning grid, the horizon-hold
becomes bounded and predictable by construction, without touching pgpm's core partitioning model.

### The one invariant

For a managed child partition `C`, the set of rows covered by `pgpm.archive_ledger` is always a
contiguous, non-overlapping, gap-free run of `[lo, hi)` ranges starting from `C`'s own `lo`.
`pgpm._archive_fully_covered(p_parent, p_child)` is true once that run reaches `C`'s own `hi` (or
the table's strategy is `none`) -- `retire()`'s archive-coverage drop precondition. Nothing here
stores a separate cursor: coverage is *derived* from the ledger on every check, so there is no
second piece of state that could drift out of sync with what was actually archived.

This is scoped per already-write-blocked child, not per managed table: `pgpm._next_archive_chunk`
picks the next chunk within one child's own `[lo, hi)`, resuming from wherever that child's own
ledger coverage left off. A child only ever becomes a candidate once the write-block trigger is
installed on it. A large child can take several `maintain()` ticks to fully archive;
`pgpm.retire()` simply will not drop it until `_archive_fully_covered` says the last chunk has
landed.

### The encoder: reading a range instead of a relation

`archive._pq_to_parquet` (the whole-relation encoder above) reads one whole child via
`array_agg(col order by ctid)`. That does not work once a file's rows can come from part of one
partition, a whole partition, or several: `ctid` identifies a row's physical location within one
heap, and is not comparable once a read spans more than one child's heap.
`archive._pq_to_parquet_range` (in [`install.sql`](install.sql)) reads straight off the *parent*
instead, relying on Postgres's own partition pruning (Append / Merge Append) to span whichever
children the `[lo, hi)` range touches -- nothing here names a child table.

Ordering matters more than it looks. A time-kind control column routinely repeats (duplicate
timestamps are the common case, not the exception), so ordering by it alone is not deterministic --
and a resumable, budget-stopped read needs a boundary that can be described exactly as `[lo, hi)`,
which is only possible if every row's sort position is unique and reproducible. So this orders by
`(control column, real key columns)` instead, discovering the key via `archive._key_columns`: a
PRIMARY KEY preferred, else a predicate/expression-free UNIQUE CONSTRAINT, never a bare UNIQUE
INDEX unbacked by a constraint. A genuinely keyless relation is refused outright -- the same
`'nokey'` contract `regrain()` already enforces.

This encoder is verified end-to-end (pyarrow + DuckDB agreeing, not just "it opened"),
independently of the pgTAP suite, by `scripts/verify_parquet_range.py` (run via `./test.sh
archive`) -- the same independent-reader bar the whole-relation encoder is held to.

### The gate is gone: `retire()` checks coverage directly

There is no separate gate function to register. `pgpm.retire()` itself will not drop a child until
`pgpm._archive_fully_covered(p_parent, p_child)` returns true -- a direct check against
`pgpm.archive_ledger`. Coverage is tracked per child from the start (`pgpm.archive_ledger`'s
primary key is `(parent_table, lo)`, one child's chunks never overlap another's), so there is
nothing to reconcile after the fact.

### The chunker: bound by byte budget, scoped to one already-eligible child

`pgpm._next_archive_chunk(p_parent, p_child)` (in `pgpm_core`; see [the
reference](../docs/reference.md#byte-budget-chunked-archiving)) picks one chunk within a single
child's own `[lo, hi)`, resuming from wherever `pgpm.archive_ledger`'s coverage of that child left
off:

- **Target byte budget** (`config.archive_byte_budget`, default 8 MiB): translated into a
  row-count limit via a sampled average row width, then extended forward to the next *distinct*
  control value past the sampled cutoff -- never splitting a run of ties across two chunks.
- **The child's own `hi`**: a child only becomes a candidate once `pgpm`'s write-block trigger is
  already installed on it -- which only happens once that child is both frozen and past the
  retention horizon. The child's own `hi` is already a safe, fixed ceiling.

`pgpm._archive_step(p_parent)`, called once per `pgpm.maintain()` tick, is the orchestrator: for
every attached child that already has the write-block trigger and is not yet fully covered, it
picks the next chunk, dispatches to whichever `archive_fn` the table's `config.archive_fn` names,
and records the result in `pgpm.archive_ledger`. A large child simply takes as many `maintain()`
ticks as its own size requires; `retire()` will not drop it early.

### Set `config.archive_fn`

```sql
update pgpm.config set archive_fn = 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure
  where parent_table = 'public.events'::regclass;
```

That is the whole installation: no gate to register, no separate schedule, no drop-trigger choice.
`pgpm.maintain()` (on the pg_cron path, `pgpm.maintain_all()`) picks up the chunking on its own
next tick, and `retire()` will not drop a partition until it is fully covered. See [the
reference](../docs/reference.md#archive-strategy-contract) for the full contract and [the
guide](../docs/guide.md#archiving-before-a-drop) for the operator's view.

### Verified end-to-end

The encoder itself (`archive._pq_to_parquet_range`, unchanged since) was verified at scale against
a live `http`-extension PostgreSQL instance and a real MinIO container: a 1,000-row, 20-day
time-kind table, deliberately including rows with duplicate timestamps, chunked with a byte budget
small enough to force many files per day, produced 57 files. Every one of the 57 was fetched back
from MinIO and read independently by pyarrow and DuckDB; the union of all 57 files' content matched
a direct database query over the same range exactly -- same row count, same ids, same order, zero
duplicates, zero drops. The `[lo, hi)` ranges across all 57 rows were confirmed programmatically
contiguous and gap-free. A second pass with compression on, on a 5,000-row table (all six types
including a nullable column), produced 112 gap-free files; every column's page in every fetched
object carried Thrift `codec = GZIP`, and the union, read independently by pyarrow and DuckDB,
matched the source rows exactly.

That verification predates the current chunk-picking, ledger, and drop-gating implementation
(re-implemented onto the `archive_fn` contract with its own, separate test coverage):
`pgpm_core`'s own `tests/63_archive_chunk_ledger_test.sql` covers the mechanical claims directly (a
multi-chunk partition archives across several `maintain()` ticks with bounded per-tick progress,
`_archive_fully_covered` flips true only once the last chunk lands, resuming across ticks never
duplicates or skips a range), and `tests/archive/db/08_archive_fn_s3_test.sql` exercises the real
S3 round-trip -- for NDJSON, by fetching the uploaded object back from MinIO and checking its row
count directly; for Parquet, by checking the ledger's own `s3_key`/`etag` fields rather than an
independent reader round-trip. That asymmetry is real and not yet closed: nothing in this
project's current CI re-verifies a chunked-Parquet object against pyarrow/DuckDB the way the
original verification above did. The underlying encoder is unchanged, so there is no specific
reason to expect a regression, but it is not directly re-checked either.

### Honest limits, for the chunked strategy

- **The byte budget is an estimate, not a guarantee.** It is derived from a sampled average row
  width, not the actual encoded Parquet size (which depends on the specific mix of column types
  and null density in that range). This bounds the horizon-hold to roughly the target, not an
  exact ceiling.
- **Sequence data before you regrain it.** `pgpm.regrain()`'s retention-aware skip discards (does
  not copy, does not error) any sub-range of a coarse child that already sits below the retention
  horizon -- correct and documented behavior for `regrain` on its own, but it runs independently of
  `config.archive_fn`: nothing checks archive coverage before a `regrain` swap discards a
  sub-range, only `retire()`'s own drop precondition does. Historical data that has not yet been
  chunked by this table's archiver is gone the moment `regrain` swaps it away. Run
  `pgpm.maintain()` (or wait for its schedule) enough times to let `pgpm._archive_fully_covered`
  catch up on the coarse child's own range before regraining it.
- **Same six types, same one-row-group shape as the whole-relation encoder.** See [honest limits,
  for the Parquet variant](#honest-limits-for-the-parquet-variant) for the full list of what is out
  of scope. NDJSON (`pgpm.archive_to_s3_ndjson`) has no such type restriction -- `row_to_json`
  round-trips any column type -- at the cost of not being directly queryable by a columnar
  analytics engine. GZIP is on by default for Parquet here, off by default for NDJSON, and its
  cost is not free against the byte budget either way (see [Two knobs that apply either
  way](#two-knobs-that-apply-either-way)): that time is part of the horizon-hold for any chunk that
  compresses, on top of the read-and-upload time the budget was already sized around.
- **Parquet cannot use a per-part-commit technique, and never will.** A Parquet file's footer
  needs every row group's byte offset, known only once the whole file's bytes exist -- there is no
  way to `COMMIT` partway through building one. This is a structural fact about the format (see
  [#211](https://github.com/dventimisupabase/pg_partition_magician/issues/211)), not a gap; each
  Parquet chunk is always single-shot regardless of the byte budget -- which is exactly why the
  byte budget, not an internal-commit technique, is what bounds the hold here.
- **The proactive alternative (archive as soon as data freezes, not gated on retention
  eligibility) is deliberately not built here.** A child only becomes archive-eligible once it is
  both frozen and past the retention horizon (the write-block trigger's own condition), so
  archiving never runs further ahead of retention than that. A proactive variant would have a real
  upside -- better DR/backup posture, no backlog pressure right at retention time -- but needs a
  periodic verification sweep plus a repair operation to correct an already-archived chunk after a
  late-arriving row, neither of which exists.

## Testing

```bash
./test.sh archive
```

Brings up a MinIO service and a `pgsql-http`-enabled PostgreSQL 17 image (see the root
[`ONBOARDING.md`](../ONBOARDING.md) for the full harness) and runs `tests/archive/db/*.sql`
against it, then `scripts/verify_parquet.py`/`verify_parquet_range.py` (independent-reader
pyarrow + DuckDB verification) against the same running instance.
