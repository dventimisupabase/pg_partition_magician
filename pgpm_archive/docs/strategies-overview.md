# Choosing an archival strategy

Three pages on this project ([Archive partitions to S3](to-s3.md), [The archive
assistant](assistant.md), [Chunked, cross-partition Parquet
archival](chunked-parquet.md)) each build a way to copy a partition's rows to S3 before
retention drops it. Read together, that can look like a pile of unrelated mechanisms. It isn't:
there are really only **two architectures**. One of them (the synchronous hook) is a single,
structurally fixed shape. The other (a paced worker with a ledger) has two independent knobs;
this page originally introduced them with only two of the four possible configurations built,
which, differing on *both* knobs at once, read as two unrelated designs rather than two corners of
the same small space. All four are built today (see the table below) -- this page exists to help
you pick an architecture and a configuration before diving into any one page's mechanics, and it
still does not replace those pages or introduce a new mechanism of its own.

**As of #222, all of it also ships as one installable module**, `pgpm_archive/install.sql`:
install it on top of `pgpm_core`, then configure one row per managed table in `archive.config`
(`boundary_rule`, `drop_trigger`, `format`, `compress`, plus connection settings) instead of
hand-copying SQL from these pages and editing constants. The three pages keep their original
hand-rolled names and code exactly as written below -- they remain the design rationale, the
honest limits, and the live-verification story -- but the module is the maintained, installable
source of truth to actually deploy. See ["Installing the module"](#installing-the-module) below
for how each page's names map onto it.

## The synchronous hook

[`pgpm.retain`](../../docs/reference.md#retain) (or a direct [`pgpm.retire`](../../docs/reference.md#retire) call)
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

Both `docs/assistant.md` and `docs/chunked-parquet.md` build the same underlying
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
  [`pgpm.retire()`](../../docs/reference.md#retire) directly once archived, registering a gate hook only as
  defense in depth against anyone else's `retain()` calls landing on the same partition.

These two knobs are independent, so there are four possible configurations. All four are built
today:

| | Gate-only (`retain()` drives the drop) | Self-driving (the worker calls `retire()` itself) |
|---|---|---|
| **Partition-aligned** | Built: [the archive assistant](assistant.md#the-scanner)'s `archive.scan()` with `c_self_driving := false` -- archives ahead of `retain()`'s own schedule, retires nothing itself. | Built (the original, and still the default): the archive assistant (`archive.partition`/`archive.scan`), NDJSON only. |
| **Byte-budget-aligned** | Built (the original, and still the default): the chunker (`archive._chunk_one`/`chunk_step`/`chunk_all` + `archive.file_gate`), Parquet only, GZIP default-on. | Built: [the chunker](chunked-parquet.md#the-chunker)'s `archive._chunk_one` with `c_self_driving := true` -- retires, right after a chunk's ledger row commits, every partition that chunk's new watermark now fully covers. This was the general form of the question [#212](https://github.com/dventimisupabase/pg_partition_magician/issues/212) raised from the Parquet-assistant angle specifically. |

The two originally-built cells sat on the diagonal: they differed on both knobs simultaneously,
which is exactly why "the assistant" and "the chunker" read as two separate architectures rather
than two settings of the same two switches. Filling in the other two cells made that visible, and
turned most of what looked like "the assistant" and "the chunker" into shared, parameterized
machinery rather than two hand-built designs: one shared `archive.ledger` table keyed by `[lo,
hi)` range (not by knob), one shared `archive.file_gate`, one shared boundary-rule shape
(`archive._next_range_partition_aligned`/`archive._next_range_byte_budget`, both `(p_parent)` in,
`(lo, hi)` or no rows out -- see [the archive assistant](assistant.md#the-scanner)), and
now one shared drop-trigger step (`archive._retire_covered`, called with the retention boundary by
a self-driving assistant or with a boundary rule's own newly-advanced watermark by a self-driving
chunker). What each page still hand-builds separately is the read-and-encode-and-upload step
itself -- NDJSON with per-part commits for the assistant, whole-range Parquet for the chunker --
which is exactly the pluggable step #221 names next.

## Two knobs that apply on top of either architecture

- **Format**: NDJSON (single-shot or with internal commits) or Parquet (single-shot only -- see
  below). NDJSON is universal and human-readable, parseable by anything that reads JSON lines, and
  round-trips any column type. Parquet is columnar and directly queryable by DuckDB, Athena,
  Redshift Spectrum, Spark, Trino, and Snowflake with no conversion step, at the cost of being a
  from-scratch, zero-dependency writer with real limits (six types, no dictionary encoding, no
  statistics, one row group -- see [Archive partitions to
  S3](to-s3.md#honest-limits-for-the-parquet-variant)).
- **Commit strategy** (NDJSON only): single-shot (the whole range's read-and-upload happens inside
  one transaction) or with internal commits (`archive._encode_upload_ndjson_commits` reads a page,
  commits, `PUT`s a part, commits, repeats). Parquet cannot do internal commits at all: its footer
  needs every row group's byte offset, known only once the whole file's bytes exist, so there is no
  way to `COMMIT` partway through building one -- a structural fact about the format
  ([#211](https://github.com/dventimisupabase/pg_partition_magician/issues/211)), not a missing
  combination.
- **Compression**: GZIP on or off, for either format now. The compressor
  (`archive._pq_gzip_compress`) takes any `bytea` and returns a valid gzip container -- it has
  nothing to do with Parquet specifically. Parquet defaults it on; NDJSON defaults it off (matching
  each format's own history) -- flip either page's `c_compress` constant to change it
  ([#221](https://github.com/dventimisupabase/pg_partition_magician/issues/221) closed #214).
  Compressing an NDJSON-with-commits range gzips each part independently and lets S3 multipart's
  own byte-range concatenation produce the final object -- RFC 1952 permits concatenating
  independent gzip members, and standard decompressors read through all of them transparently.

As of #221, the boundary rule (partition-aligned vs byte-budget-aligned), the drop-trigger rule
(gate-only vs self-driving), the format (NDJSON vs Parquet), and the commit strategy (single-shot
vs internal commits, NDJSON only) are all independent, pluggable choices on both
`archive.partition` and `archive._chunk_one` -- a `c_format` constant on each dispatches to one of
three shared `archive._encode_upload_*` steps
([defined once](assistant.md#the-archiver)). Today's original pairing (NDJSON-with-commits
for the assistant, compressed Parquet for the chunker) remains each page's default, but is no
longer a structural coupling -- it never really was one, just an accident of build order, and #221
is what actually lets you pick otherwise. The byte-budget-aligned NDJSON worker
([#213](https://github.com/dventimisupabase/pg_partition_magician/issues/213)) that was once its
own open question is exactly `archive._chunk_one` with `c_format := 'ndjson_single'` or
`'ndjson_commits'` -- no separate implementation needed.

One more knob, but only where it can matter:

- **Transport** (the synchronous hook only -- the paced worker already bounds file/part size a
  different way, so it doesn't need this): single PUT or multipart PUT. Multipart only helps a
  format whose reader can genuinely stream row-by-row across parts (NDJSON); it does not raise
  Parquet's ceiling, because the whole file has to be built in memory before the first part can be
  sent regardless of how many parts it's split into afterward (#211).

## What's built, what's a gap

- The synchronous hook: NDJSON built (single-PUT and multipart, no compression); Parquet built
  (single-PUT, GZIP default-on) -- multipart Parquet is an open question, not a clear gap (#211).
- The paced worker: all four boundary-rule x drop-trigger-rule configurations are built -- see the
  table above -- and, as of #221, all three encode/upload combinations (NDJSON single-shot, NDJSON
  with internal commits, Parquet single-shot) are pluggable on either one via `c_format`. Parquet
  with internal commits is the one combination that is not, and cannot be, built (#211's format
  constraint).
- Compression is no longer a gap on either format: `c_compress` works on Parquet (default on) and
  NDJSON (default off, either commit strategy) alike -- #214 closed.
- The byte-budget-aligned NDJSON worker -- #213 -- closed: it is `archive._chunk_one` with
  `c_format := 'ndjson_single'` or `'ndjson_commits'`, independent of which drop-trigger rule it
  uses.

## Choosing among them

Start from the architecture, not the format:

- Partitions are small enough (or your vacuum tolerance is loose enough) that holding the horizon
  for one partition's read-and-upload doesn't worry you: **the synchronous hook**. Pick NDJSON for
  the simplest possible consumer story, or Parquet if you want the archive directly queryable by
  an analytics engine without a conversion step.
- You want the tightest vacuum-horizon bound this project builds, one file per partition, and a
  scanner owning drop timing instead of `retain()`'s own schedule: **the archive assistant**
  (partition-aligned, self-driving -- its default). NDJSON with internal commits by default, but
  `c_format` also picks single-shot NDJSON or Parquet.
- Partition sizes are large or uneven, and you want file size to be a deliberate operational
  choice rather than emergent, with `retain()` still deciding when partitions actually drop:
  **the chunker** (byte-budget-aligned, gate-only -- its default). Compressed Parquet by default,
  but `c_format` also picks either NDJSON variant.
- Want a different pairing than either page's default -- partition-aligned but gate-only,
  byte-budget-aligned but self-driving, NDJSON on the chunker, or Parquet on the assistant? Every
  knob is independent: `c_self_driving` picks the drop-trigger rule and `c_format` picks the
  encode/upload step, on either page, regardless of which boundary rule you started from -- no
  need to wait on which combination someone else built first.

Whichever you pick, compression is close to free to turn on wherever it's wired (it costs real,
non-trivial time -- see [Chunked, cross-partition Parquet archival's byte-budget
guidance](chunked-parquet.md#the-chunker) for measured numbers -- but no design tradeoff
beyond that), and multipart transport only matters for the synchronous hook, and only really helps
NDJSON.

## Installing the module

Everything above is a map of the *design space*, not an installation guide -- `pgpm_archive/
install.sql` is. It ships every function/procedure named on this page and its three siblings,
verbatim where the code is unchanged, plus one real addition: `archive.config`, one row per
managed table, replacing every "deployment constants: edit these N" block below with an operator
interface (`archive.configure`/`archive.schedule`, no hand-editing SQL, no raw `insert`/`update`
against the catalog). Install it on top of `pgpm_core`:

```sql
\i pgpm_core/install.sql
\i pgpm_archive/install.sql

select archive.configure('public.events', 'my-archive-bucket',
  p_region        => 'us-east-1',
  p_boundary_rule => 'partition_aligned',   -- or 'byte_budget'
  p_drop_trigger  => 'self_driving',        -- or 'gate_only'
  p_format        => 'ndjson_commits');     -- or 'ndjson_single' / 'parquet'

select pgpm.hook_register('public.events', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select archive.schedule();   -- one standing job, every configured table
```

The three implementation pages below kept their original hand-rolled names and `c_`-prefixed
"deployment constants" throughout -- they remain the design rationale, the honest limits, and the
live-verification write-ups those names were verified under. The module renamed a few things while
unifying them; this table is the map from what a page says to what the module actually ships:

| This page says | The module ships | Notes |
|---|---|---|
| `archive.partition(parent, child)` | `archive.archive_partition(parent, child)` | same forward-only guard; now dispatches through `archive.archive_range` |
| `archive.scan()` | `archive.tick()` | the one standing worker, loops every `archive.config` row of either boundary rule |
| `archive._chunk_one(parent)` | `archive._tick_one(parent)` | picks the next range per `boundary_rule`, then calls `archive.archive_partition` or `archive.archive_range` |
| `archive.chunk_step(parent)` | folded into `archive.tick()` | no longer a separate per-table cron entry -- one job covers every configured table |
| `archive.chunk_all(parent)` | `archive.run_all(parent)` | the operator's "do it now", either boundary rule |
| `c_self_driving` | `archive.config.drop_trigger` | `'self_driving'` \| `'gate_only'` |
| `c_format` | `archive.config.format` | `'ndjson_single'` \| `'ndjson_commits'` \| `'parquet'` |
| `c_compress` | `archive.config.compress` | boolean |
| `c_byte_budget` / `c_probe_sample` | `archive.config.byte_budget` / `archive.config.probe_sample` | byte-budget rule only |
| `c_part_bytes` / `c_fetch_rows` | `archive.config.part_bytes` / `archive.config.fetch_rows` | `ndjson_commits` format only |
| `c_bucket` / `c_region` / `c_prefix` / `c_endpoint` | `archive.config.bucket` / `region` / `prefix` / `endpoint` | one connection per managed table, not per function |
| hardcoded `'s3_archive_access_key_id'` / `'s3_archive_secret_access_key'` | `archive.config.vault_key_id` / `vault_secret` | same defaults, now configurable per table |
| `archive.to_s3` / `archive.to_s3_parquet` | same names | unchanged architecture (still the synchronous hook), now reading connection settings from `archive.config` too |
| a raw `insert`/`update` on `archive.config` | `archive.configure(parent, bucket, ...)` | one function, an upsert; never hand-edit the catalog directly |
| a raw `cron.schedule(...)` call | `archive.schedule([interval])` / `archive.unschedule()` | same shape as `pgpm.schedule()`/`pgpm.unschedule()` |

## Positioning

This page is a map, not a fourth mechanism. `archive.to_s3`, `archive.to_s3_parquet`, and the
paced worker's two boundary rules all continue to work exactly as their own pages describe;
nothing here changes their behavior or supersedes their own "Honest limits" sections. The
reframing above (one fixed architecture, one two-knobbed architecture, all four configurations
built) is a way of reading what's already there. Since #221, the ledger, the gate, the
boundary-rule dispatch, the drop-trigger step, *and* the encode/upload step were already shared
machinery (`archive.ledger`, `archive.file_gate`,
`archive._next_range_partition_aligned`/`archive._next_range_byte_budget`,
`archive._retire_covered`, `archive._encode_upload_ndjson_single`/`_ndjson_commits`/`_parquet`);
what was left unmerged was just the two entry points themselves, `archive.partition` (told which
partition by its caller) and `archive._chunk_one` (picks its own range). #222 closed that last
gap and packaged the result as `pgpm_archive/install.sql` (see ["Installing the
module"](#installing-the-module) above): `archive.archive_partition`/`archive.archive_range` (the
archiver), `archive._tick_one` (picks a range per `boundary_rule`), and
`archive.tick()`/`archive.run_all(parent)` (the standing and do-it-now entry points) are one
config-driven worker, the same code path regardless of which knobs a table uses. The three
implementation pages below are unaffected by that packaging -- they describe the same mechanisms
under their original names, and remain the place to read *why* each piece works the way it does.
