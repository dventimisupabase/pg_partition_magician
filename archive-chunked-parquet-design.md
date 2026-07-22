# Design context: chunked, cross-partition Parquet archival

Handoff pack for a fresh session. Read this instead of reconstructing the reasoning from scratch;
the reasoning already happened, in a design conversation that isn't otherwise persisted anywhere.
Delete or archive this file once the implementation it describes has landed and the design has
been superseded by the actual code + docs.

## Who's reading this / conventions

Same conventions as the rest of this repo: PostgreSQL specialist level, don't explain MVCC/vacuum/
partitioning basics. `pg_partition_magician` (pgpm) is generic, not Supabase-specific, even though
some verification below used Supabase-shaped constraints (statement_timeout, Storage upload
limits) as a stand-in for "a managed Postgres with real ceilings." No em dashes anywhere (house
style, prose and code comments alike). Where lock/encoding/protocol behavior matters, verify it
empirically against a real instance before asserting it; don't reason from memory when a five-line
docker command would confirm it directly. TDD: write the failing test before the implementation.

## What's already shipped (don't re-derive, build on it)

- **#199**: the original issue proposing Parquet/Iceberg as an archive format, with a
  de-prioritization comment (NDJSON + downstream conversion via Athena/Glue is enough, until it
  isn't) and a later reframing comment (pg_parquet no longer available on Supabase; some customers
  can't stand up Athena/Glue either, so a zero-dependency in-database writer earns its keep).
- **`prototypes/parquet-writer/`**: a hand-rolled Parquet writer in pure PL/pgSQL (Thrift compact
  protocol footer, PLAIN encoding, one row group, `OPTIONAL`-column definition levels for nullable
  columns), zero extension dependencies. Field IDs/encodings verified against the canonical
  `apache/parquet-format` `parquet.thrift` and `Encodings.md`, not memory. `verify.py` checks
  output with two independent readers (pyarrow + DuckDB) agreeing on value equality, not just "it
  opened". 20 cases green as of the last run.
- **`docs/archive-to-s3.md`**, section "A columnar variant: Parquet instead of NDJSON": the same
  encoder renamed into the `archive` schema (`archive._pq_*` helpers, entry point
  `archive._pq_to_parquet(p_relation regclass) returns bytea` at line ~910), a bytea-native SigV4
  signer `archive.s3_signed_request_bytea` (line ~1001, needed because the existing
  `archive.s3_signed_request` hashes via `digest(convert_to(payload, 'UTF8'), 'sha256')`, which
  raises on real Parquet binary content), and the hook itself,
  `archive.to_s3_parquet(p_parent regclass, p_child name, p_lo text, p_hi text)` (line ~1066).
  Verified end-to-end through a real `pgpm.retire()` call against MinIO (happy path, a broken-
  endpoint veto, self-repair on retry, a nullable-column case with 10/30 rows null, cross-checked
  by both readers).
- **PR #200** (initial writer + hook), **PR #201** (NULL support): both merged to `main`.
- **The verification recipe**, reusable for whatever comes next: `docker-compose --profile pg17`
  for the core encoder TDD loop (the project's own `Dockerfile` has no `http`/`pgcrypto`, only
  `pg_cron`/`pgtap`); for a full hook-through-`retire()` test, a throwaway image built from
  `postgres:17` + `pgsql-http` built from source (same technique the project's own `Dockerfile`
  already uses for `pg_cron`), plus a `minio/minio` container on a shared docker network, plus a
  stub `vault.decrypted_secrets` table (this repo's plain Postgres images have no real Vault).
  `pgpm_core/install.sql` installs cleanly without `pg_cron` (only needed for `schedule()`).

## The problem this design solves

`archive.to_s3_parquet` holds the vacuum horizon for as long as one partition's read+encode+upload
takes. The encoder pulls every column via `array_agg(col order by ctid)` with no `COMMIT` in
between, because each column's array has to come from the same snapshot as every other column's or
a concurrent write could misalign rows across columns. That's fine and bounded for a small
partition; it's the same shape (and ceiling) as the basic synchronous `archive.to_s3` hook, not the
per-part-committing `archive-assistant.md` design. But partition size under time-cut partitioning
is emergent (ingest rate x row width x interval), not bounded by the partitioning DDL at all, so the
horizon-hold is unbounded in the worst case (a busy month next to a quiet one).

A design-space conversation considered four options for bounding this (size-cut partitions as
pgpm's fundamental unit; a size-aware exporter; a coarser/finer calendar grid as a ceiling; status
quo). The one that actually won isn't cleanly any of those: **decouple Parquet files from partition
boundaries entirely.**

## The design decided

**The core reframing**: the Parquet footer's "must know every row group's byte offset before
writing it" constraint was never a *partition* constraint, it's a *file* constraint. Once a file's
size is chosen independently of partition boundaries, you get bounded, predictable horizon-holds
for free, without touching pgpm's core partitioning model and without needing an external worker.

**The one invariant** (this is the load-bearing sentence, everything else derives from it): for
parent table P, the set of rows in a new ledger table is always a contiguous, non-overlapping,
gap-free run of `[lo, hi)` ranges starting from P's archival floor. The watermark for P is
`max(hi)` over that run, and everything below it is guaranteed durably archived (uploaded,
confirmed, ledgered).

**Schema** (new, additive; does not touch `archive.ledger`/`archive.gate` from archive-assistant.md,
see positioning below):

```sql
create table if not exists archive.file_ledger (
  parent_table  regclass    not null,
  lo            text        not null,   -- text-encoded, same kind-aware convention as pgpm.config lo/hi
  hi            text        not null,
  s3_key        text        not null,
  etag          text,
  rows_archived bigint      not null,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)        -- lo uniquely identifies a file: ranges never overlap
);
create index on archive.file_ledger (parent_table, hi desc);   -- makes max(hi) cheap
```

No separate persisted-cursor table: the watermark is *derived* (`select max(hi) from
archive.file_ledger where parent_table = P`), not duplicated state kept in sync by hand. It serves
both the chunker's "where do I resume" question and the gate's "is this range archived" question
with the same query.

**The chunker's stopping rule, decided (Option A, not B)**: each file covers
`[watermark(P), stop)` where `stop = min(target byte budget, frozen floor, retention horizon)`.
The frozen floor is the same concept `pgpm.regrain_step` already computes (whole range at/below the
current grid floor, so no live write can still land there per pgpm's obtain-ahead guarantee). The
retention horizon bound is the deliberate choice: **the chunker never archives further ahead than
data that's already retention-eligible.** This makes it a generalized version of what
`archive.scan()` already does today (find retention-eligible partitions, archive them), just
batched across partition boundaries for file-sizing instead of one file per partition, rather than
a proactive archiver decoupled from retention timing.

**Why not the proactive version** (archive as soon as data freezes, regardless of retention
horizon): it's a real, nice property (much better DR/backup posture, no backlog-pressure-at-
retention-time scenario) but it opens a long window between "file N is archived" and "the partition
it covers actually gets dropped" -- during which a backdated/late-arriving row could land in that
already-archived-but-still-attached partition. The chunker is forward-only (advances the watermark,
never revisits an already-ledgered file), so there's no "next pass fixes it" the way
`archive.scan()` naturally re-archives a stale child in the existing per-partition model. Filed as
**#202**, explicitly may never be implemented: needs a periodic verification sweep (detection) plus
an `archive.repatch(parent, lo)`-shaped operation (re-read the exact already-ledgered range,
rebuild, re-PUT to the same key, update the ledger row in place -- compatible with the invariant
since it corrects existing coverage rather than extending it). Not needed for the chosen design:
Option A's window is bounded by scan cadence (short), not calendar time (long), so the existing
gate's recount defense below is enough on its own.

**The gate, two-part** (replaces the per-child count comparison in `archive.gate` for whatever
uses this new chunker; the existing `archive.gate`/`archive.ledger` stay as-is for the
per-partition model, see positioning):

1. Fast path: `p_hi <= watermark(p_parent)` (derived, no scan). False means not archived yet, defer.
2. Defense in depth: for every `file_ledger` row overlapping `[p_lo, p_hi)`, recount that file's
   *entire* range live and compare to its recorded `rows_archived`. A mismatch anywhere in that
   file's range defers the drop of the partition being checked, even if the actual stray landed in
   a sibling partition sharing the same file. This is intentionally conservative (a shared-file-
   boundary stray transiently blocks an unrelated partition's drop until the next chunk pass
   re-archives it clean) but it is not a bug: it's the honest cost of a per-*file* count with no
   per-partition breakdown recorded, and it fails safe (defers) rather than silently dropping
   something that changed. Named cost, not glossed over: the recount scans the whole file's range,
   which is bigger than one partition by design, so it's more expensive per retire() attempt than
   the old per-child check was, not less.

**Ordering/tiebreaker requirement**: cross-partition keyset pagination can't order by `ctid` (not
comparable across child tables). Ordering by the control column alone is only deterministic if that
column is unique -- a real risk for time-kind control columns (duplicate timestamps are common),
much less so for id/uuidv7. A chunk boundary landing mid-run-of-ties, resumed with a plain
inequality, risks duplicating rows into two files or silently dropping them. Needs a composite
resume point (control value + a genuine tiebreaker, i.e. the table's actual key), mirroring
`pgpm.regrain_step`'s own key-discovery logic (`v_keyidx`/`v_pkjoin`, `pgpm_core/install.sql` around
line 821-834: prefers a primary key, falls back to a predicate/expression-free unique constraint,
refuses `'nokey'` for genuinely keyless tables). Reuse that discovery logic rather than
reinventing it; a keyless table should refuse this chunker for the same reason `regrain` already
refuses it, that's an inherited constraint, not a new gap.

**What actually needs to change in existing code** (none of this exists yet):

- `archive._pq_to_parquet(p_relation regclass)` today does `SELECT ... FROM <one specific
  relation>` for every column (see `archive._pq_encode_column_data` in `docs/archive-to-s3.md`).
  The chunker needs a variant that reads a bounded range from the *parent*, not one whole child:
  `SELECT ... FROM parent WHERE control_col >= lo AND control_col < hi ORDER BY control_col
  [, tiebreaker]`, relying on Postgres's own partition pruning (Append/Merge Append) to span
  whichever children the range touches transparently. This is a real signature/internals change to
  the encoder's column-extraction step, not just a new caller wrapping the existing one.
- New: `archive.file_ledger` (schema above).
- New/changed: a watermark-based gate (two-part check above), distinct from the existing
  `archive.gate` (which stays for the per-partition model).
- New: a chunk-step procedure. Mirror `pgpm.regrain_step`/`pgpm.regrain`'s two driving modes as a
  template: a synchronous "do it now" driver that loops steps in one go (`pgpm.regrain`'s shape),
  or one step per `maintain()`/cron tick for a paced backlog (matches how `archive.scan()` already
  works). Whichever mode, each *file* (not each step necessarily) needs its own COMMIT to actually
  bound the horizon-hold -- this is a procedure, like `archive.partition`, not a pure function.
  Single-writer via a session advisory lock, same pattern as `archive.scan()`'s
  `pg_try_advisory_lock(hashtext('pgpm-archiver'))` -- pick a distinct lock key for this chunker so
  it doesn't collide with the existing scanner if both might ever run.

## Positioning

This is a new, parallel archival strategy, not a replacement. `archive.ledger` / `archive.gate` /
`archive.partition` (archive-assistant.md's existing per-partition, per-part-committing model) stay
exactly as they are for anyone who doesn't need cross-partition chunking. This would live under its
own names and probably its own doc page (the way `archive-assistant.md` already sits alongside
`archive-to-s3.md` as a variant, not a rewrite), reusing the Parquet encoder and the bytea SigV4
signer, not duplicating them.

## Explicitly not part of this thread

Compression (PGLZ/LZ4 TOAST is real and common but not callable as a general-purpose "compress
this bytea" primitive; no clean path found, separately discussed, deliberately parked) is a
different, later conversation. Don't fold it into this implementation pass.

## Suggested first steps

1. New branch, Conventional Branches naming (e.g. `feat/chunked-parquet-archival`).
2. TDD the key-discovery + cross-partition range-query adaptation of the encoder first: it's the
   smallest independently testable unit, and the tiebreaker requirement is exactly the kind of
   thing that fails silently and expensively if gotten wrong (duplicated or dropped rows across a
   chunk boundary), so a targeted red/green test for a non-unique control column with a real key
   should come before anything else.
3. Then `archive.file_ledger` + the derived watermark query.
4. Then the two-part gate.
5. Then the chunk-step procedure (pick synchronous-loop vs per-tick mode, or offer both like
   regrain does).
6. Wire + verify end-to-end the same way as before: real `pgpm.retire()`/`retain()` calls against a
   live MinIO instance, pyarrow + DuckDB agreeing, a deliberately-provoked gate-defers-the-drop
   case, not just the happy path.
