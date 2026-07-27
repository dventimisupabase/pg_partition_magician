# Chunked, cross-partition Parquet archival: bounding the horizon by file size

The byte-budget archival strategy, alongside [Archive partitions to S3](to-s3.md)'s synchronous
functions: instead of archiving one partition into one file, this decouples Parquet (or NDJSON)
files from partition boundaries entirely, so a file's size (and therefore its vacuum-horizon hold)
is a deliberate, bounded choice, never an emergent consequence of how big a partition happened to
grow. It reuses the [Parquet encoder](to-s3.md#a-columnar-variant-parquet-instead-of-ndjson) and the
bytea-native SigV4 signer from that page rather than duplicating them.

This is the mechanism behind `pgpm.config.archive_fn` (see
[`docs/retention-write-block-and-merge.md`](../../docs/retention-write-block-and-merge.md), #242):
`pgpm_core` itself now drives byte-budget chunked archiving as part of `pgpm.maintain()`, ahead of
every drop, and `pgpm.retire()` will not drop a partition until its own coverage check
(`pgpm._archive_fully_covered`) says archiving has actually caught up -- no separate gate function
to register, no drop-trigger choice to make. Setting `pgpm.config.archive_fn` to
`pgpm.archive_to_s3_parquet` (this page's format) or `pgpm.archive_to_s3_ndjson` rides that
mechanism directly; see [the reference](../../docs/reference.md#archive-strategy-contract) for the
full contract and [the guide](../../docs/guide.md#archiving-before-a-drop) for the operator's view.
This page stays focused on *why* bounding by file size beats bounding by partition size, and on the
Parquet range encoder's own design and honest limits -- the chunk-picking and coverage-tracking
mechanics live in `pgpm_core` now, not in this module.

## Why partition size is the wrong unit to bound

The single-PUT Parquet function ([Archive partitions to S3](to-s3.md)) bounds its vacuum-horizon
hold in terms of *partitions* -- one whole partition's read+upload. That is fine as long as a
partition's size is itself bounded, but under time-cut partitioning, partition size is emergent --
ingest rate x row width x interval -- not something the partitioning DDL controls at all. A busy
month sitting next to a quiet one means some partitions are ten times the size of their neighbors,
and the function's horizon-hold grows in lockstep with whichever partition happens to be up for
archiving.

The fix is not a size-aware exporter bolted onto the existing per-partition model, nor a finer
partitioning grid picked defensively for the worst case. Parquet's footer needs every row
group's byte offset known before it is written, which sounds like a per-*file* constraint tied
to a partition -- but it is really just a constraint on **whatever range of rows becomes one
file**, and nothing requires that range to line up with a partition boundary. Once a file's
size is chosen independently of the partitioning grid, the horizon-hold becomes bounded and
predictable by construction, without touching pgpm's core partitioning model.

## The one invariant

For a managed child partition `C`, the set of rows covered by `pgpm.archive_ledger` is always a
contiguous, non-overlapping, gap-free run of `[lo, hi)` ranges starting from `C`'s own `lo`.
`pgpm._archive_fully_covered(p_parent, p_child)` is true once that run reaches `C`'s own `hi` (or
the table's strategy is `none`) -- `retire()`'s archive-coverage drop precondition. Nothing here
stores a separate cursor: coverage is *derived* from the ledger on every check, so there is no
second piece of state that could drift out of sync with what was actually archived.

This is scoped per already-write-blocked child, not per managed table: `pgpm._next_archive_chunk`
picks the next chunk within one child's own `[lo, hi)`, resuming from wherever that child's own
ledger coverage left off. A child only ever becomes a candidate once the write-block trigger is
installed on it (`docs/retention-write-block-and-merge.md`, #242) -- that gating, and the frontier/
retention-horizon math behind it, is `pgpm_core`'s job now, not this page's. A large child can take
several `maintain()` ticks to fully archive; `pgpm.retire()` simply will not drop it until
`_archive_fully_covered` says the last chunk has landed.

## The encoder: reading a range instead of a relation

`archive._pq_to_parquet` (the existing Parquet encoder) reads one whole child via
`array_agg(col order by ctid)`. That does not work once a file's rows can come from part of one
partition, a whole partition, or several: `ctid` identifies a row's physical location within one
heap, and is not comparable once a read spans more than one child's heap. The range variant
below reads straight off the *parent*, relying on Postgres's own partition pruning (Append /
Merge Append) to span whichever children the `[lo, hi)` range touches -- nothing here names a
child table.

Ordering matters more than it looks. A time-kind control column routinely repeats (duplicate
timestamps are the common case, not the exception), so ordering by it alone is not
deterministic -- and a resumable, budget-stopped read needs a boundary that can be described
exactly as `[lo, hi)`, which is only possible if every row's sort position is unique and
reproducible. So this orders by `(control column, real key columns)` instead, discovering the
key via `archive._key_columns` -- [Archive partitions to
S3](to-s3.md#a-columnar-variant-parquet-instead-of-ndjson)'s shared key-discovery helper,
reused as-is here: a PRIMARY KEY preferred, else a predicate/expression-free
UNIQUE CONSTRAINT, never a bare UNIQUE INDEX unbacked by a constraint. A genuinely keyless relation
is refused outright -- the same `'nokey'` contract `regrain()` already enforces, an inherited
limitation, not a new gap. (On a partitioned parent, Postgres itself requires any unique constraint
to include every partitioning column, so in practice the control column is always already one of
the columns this discovers.)

`archive._pq_encode_column_data` already takes the `p_order_by` parameter this range reader
needs (default `'ctid'`, so `archive._pq_to_parquet`'s whole-relation callers are unaffected
byte-for-byte) -- see its definition in [Archive partitions to
S3](to-s3.md#a-columnar-variant-parquet-instead-of-ndjson). It is deliberately not
redeclared here: Postgres overload resolution is keyed on the parameter type list, not names or
defaults, so a second definition with a different arity would coexist as a distinct overload
rather than replace the original, and a 4-arg call from `archive._pq_to_parquet` would become
ambiguous between the two (#209). Install `to-s3.md`'s SQL first; everything below
builds on it.

```sql
-- archive._pq_to_parquet_range: reads [p_lo, p_hi) of p_control off p_parent (typically a
-- partitioned parent), relying on Postgres's own partition pruning. p_lo/p_hi are literals
-- already typed for p_control's actual column type -- e.g. for a uuidv7-kind control column,
-- translate a pgpm native-grid (timestamptz) value via pgpm._encode first, the same way
-- pgpm.regrain_step builds its own v_lo_lit/v_hi_lit before using them.
create or replace function archive._pq_to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text, p_compress boolean default true) returns bytea
language plpgsql as $$
declare
  v_schema name; v_table name; v_from_sql text; v_order_by text; v_key_cols name[];
  v_col record;
  v_col_names text[] := '{}';
  v_col_pgtypes text[] := '{}';
  v_col_ptypes int4[] := '{}';
  v_col_converted int4[] := '{}';
  v_col_nullable boolean[] := '{}';
  v_ncols int4;
  v_num_rows bigint;
  v_magic bytea := convert_to('PAR1', 'UTF8');
  v_body bytea;
  v_data bytea; v_page_bytes bytea; v_page_header bytea; v_page_offset bigint;
  v_column_chunks bytea[] := '{}';
  v_schema_elements bytea[] := '{}';
  v_total_uncompressed bigint;
  v_row_group bytea;
  v_schema_list bytea[];
  v_footer bytea;
  i int4;
begin
  select n.nspname, c.relname into v_schema, v_table
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.oid = p_parent;

  v_key_cols := archive._key_columns(p_parent);
  if v_key_cols is null then
    raise exception 'archive._pq_to_parquet_range: % has no primary key or predicate/expression-free unique constraint; a resumable cross-partition range read cannot tiebreak ties on % without one (the same refusal pgpm.regrain_step already makes for keyless tables)',
      p_parent, p_control;
  end if;
  select string_agg(quote_ident(c), ', ' order by ord) into v_order_by
    from unnest(v_key_cols) with ordinality as t(c, ord);
  v_order_by := quote_ident(p_control) || ', ' || v_order_by;

  v_from_sql := format('(select * from %I.%I where %I >= %L and %I < %L) x',
                        v_schema, v_table, p_control, p_lo, p_control, p_hi);

  for v_col in
    select a.attname, a.attnotnull, t.typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
    where a.attrelid = p_parent and a.attnum > 0 and not a.attisdropped
    order by a.attnum
  loop
    v_col_names := v_col_names || v_col.attname;
    v_col_nullable := v_col_nullable || (not v_col.attnotnull);

    case v_col.typname
      when 'int4'        then v_col_pgtypes := v_col_pgtypes || 'int4'::text;        v_col_ptypes := v_col_ptypes || 1; v_col_converted := v_col_converted || -1;
      when 'int8'        then v_col_pgtypes := v_col_pgtypes || 'int8'::text;        v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || -1;
      when 'float8'      then v_col_pgtypes := v_col_pgtypes || 'float8'::text;      v_col_ptypes := v_col_ptypes || 5; v_col_converted := v_col_converted || -1;
      when 'bool'        then v_col_pgtypes := v_col_pgtypes || 'bool'::text;        v_col_ptypes := v_col_ptypes || 0; v_col_converted := v_col_converted || -1;
      when 'text'        then v_col_pgtypes := v_col_pgtypes || 'text'::text;        v_col_ptypes := v_col_ptypes || 6; v_col_converted := v_col_converted || 0;
      when 'timestamptz' then v_col_pgtypes := v_col_pgtypes || 'timestamptz'::text; v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      when 'timestamp'   then v_col_pgtypes := v_col_pgtypes || 'timestamp'::text;   v_col_ptypes := v_col_ptypes || 2; v_col_converted := v_col_converted || 10;
      else raise exception 'archive._pq_to_parquet_range: unsupported column type % for column %', v_col.typname, v_col.attname;
    end case;
  end loop;

  v_ncols := array_length(v_col_names, 1);
  if v_ncols is null then
    raise exception 'archive._pq_to_parquet_range: relation % has no supported columns', p_parent;
  end if;

  execute format('select count(*) from %s', v_from_sql) into v_num_rows;

  v_body := v_magic;
  for i in 1..v_ncols loop
    v_data := archive._pq_encode_column_data(v_from_sql, v_col_names[i], v_col_pgtypes[i], v_col_nullable[i], v_order_by);
    if p_compress then
      v_page_bytes := archive._pq_gzip_compress_dynamic(v_data);
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data), length(v_page_bytes));
    else
      v_page_bytes := v_data;
      v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    end if;
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_page_bytes;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset,
          case when p_compress then 2 else 0 end,
          case when p_compress then length(v_page_header) + length(v_page_bytes) else null end));
    v_schema_elements := v_schema_elements || archive._pq_build_schema_leaf(v_col_names[i], v_col_ptypes[i], v_col_converted[i], v_col_nullable[i]);
  end loop;

  v_row_group := archive._pq_build_row_group(v_column_chunks, length(v_body) - length(v_magic), v_num_rows);

  v_schema_list := array_prepend(archive._pq_build_schema_root(v_ncols), v_schema_elements);
  v_footer := archive._pq_build_file_metadata(v_schema_list, v_num_rows, array[v_row_group]);

  return v_body || v_footer || archive._pq_reverse_bytes(int4send(length(v_footer))) || v_magic;
end;
$$;
```

A prototype of this same encoder, with its own from-scratch test tables and both readers
verifying it independently, lives in
[`prototypes/parquet-writer/`](../../prototypes/parquet-writer/README.md#the-cross-partition-range-variant)
-- the standalone spike this section grew from, same as the whole-relation encoder before it.

## The gate is gone: `retire()` checks coverage directly

There is no separate gate function to register anymore. `pgpm.retire()` itself will not drop a
child until `pgpm._archive_fully_covered(p_parent, p_child)` returns true -- a direct check against
`pgpm.archive_ledger`, not a recount-based veto living in this module. That sidesteps the old
design's whole reason for a "defense in depth" recount (one archived *file* could cover parts of
several partitions, so a per-partition drop needed to recheck a shared file's count): coverage is
now tracked per child from the start (`pgpm.archive_ledger`'s primary key is `(parent_table, lo)`,
one child's chunks never overlap another's), so there is nothing to reconcile after the fact.

## The chunker: bound by byte budget, scoped to one already-eligible child

`pgpm._next_archive_chunk(p_parent, p_child)` (in `pgpm_core`; see
[the reference](../../docs/reference.md#byte-budget-chunked-archiving)) picks one chunk within a
single child's own `[lo, hi)`, resuming from wherever `pgpm.archive_ledger`'s coverage of that child
left off:

- **Target byte budget** (`config.archive_byte_budget`, default 8 MiB): translated into a row-count
  limit via a sampled average row width (`config.archive_probe_sample` rows, the same technique
  `pgpm.regrain_step`'s `drain_max_blocks` path already uses), then extended forward to the next
  *distinct* control value past the sampled cutoff -- never splitting a run of ties across two
  chunks.
- **The child's own `hi`**: unlike the original design (which had to compute a frozen floor and a
  retention horizon itself, since nothing else gated eligibility), a child only becomes a candidate
  once `pgpm`'s write-block trigger is already installed on it -- which only happens once that
  child is both frozen and past the retention horizon (`docs/retention-write-block-and-merge.md`,
  #242). The child's own `hi` is already a safe, fixed ceiling; there is no separate floor/horizon
  math to redo here.

`pgpm._archive_step(p_parent)`, called once per `pgpm.maintain()` tick, is the orchestrator: for
every attached child that already has the write-block trigger and is not yet fully covered, it
picks the next chunk, dispatches to whichever `archive_fn` the table's `config.archive_fn` names
(`pgpm.archive_to_s3_parquet` for this page's format), and records the result in
`pgpm.archive_ledger`. There is no separate paced/do-it-now entry point and no drop-trigger choice
to make: `pgpm.maintain()`'s own schedule drives the chunking, and `pgpm.retire()`'s own drop
precondition -- write-blocked and archive-covered -- is unconditional, not a per-table option. A
large child simply takes as many `maintain()` ticks as its own size requires; `retire()` will not
drop it early.

`_key` is built from the native `lo` value stripped to digits only (not the raw text): a raw
native-grid value like `2000-01-01 00:00:00+00` contains a `+`, and the existing SigV4 signer
does not URL-encode the key (by design, on the assumption that keys stay unreserved-URL-clean --
see [Archive partitions to S3](to-s3.md#honest-limits)); an unencoded `+` in the path
produces a real `SignatureDoesNotMatch` against S3-compatible stores, caught by trying it.

## Install

```sql
update pgpm.config set archive_fn = 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure
  where parent_table = 'public.events'::regclass;
```

That is the whole installation: no gate to register, no separate schedule, no drop-trigger choice.
`pgpm.maintain()` (on the pg_cron path, `pgpm.maintain_all()`) picks up the chunking on its own next
tick, and `retire()` will not drop a partition until it is fully covered. See
[the reference](../../docs/reference.md#archive-strategy-contract) for the full contract and
[the guide](../../docs/guide.md#archiving-before-a-drop) for the operator's view (how to watch
progress, what a stuck coverage check looks like).

## Verified end-to-end

The encoder itself (`archive._pq_to_parquet_range`, unchanged since) was verified at scale against a
live `http`-extension PostgreSQL instance and a real MinIO container, driven by this design's
original chunk-picking implementation: a 1,000-row, 20-day time-kind table, deliberately including
rows with duplicate timestamps, chunked with a byte budget small enough to force many files per day,
produced 57 files. Every one of the 57 was fetched back from MinIO and read independently by pyarrow
and DuckDB; the union of all 57 files' content matched a direct database query over the same range
exactly -- same row count, same ids, same order, zero duplicates, zero drops. The `[lo, hi)` ranges
across all 57 rows were confirmed programmatically contiguous and gap-free (`lag(hi) over (order by
lo)` equals the next `lo`, everywhere). A second pass with `c_compress := true` on a 5,000-row table
(all six types including a nullable column) produced 112 gap-free files; every column's page in
every fetched object carried Thrift `codec = GZIP`, and the union, read independently by pyarrow and
DuckDB, matched the source rows exactly.

That verification predates this page's current form: the chunk-picking, ledger, and drop-gating
described above were re-implemented onto the `archive_fn` contract (#237-#240), with their own,
separate test coverage rather than a rerun of the above. `pgpm_core`'s own
`tests/63_archive_chunk_ledger_test.sql` covers the mechanical claims for the current implementation
directly: a multi-chunk partition archives across several `maintain()` ticks with bounded per-tick
progress, `_archive_fully_covered` flips true only once the last chunk lands, and resuming across
ticks never duplicates or skips a range. `tests/archive/db/08_archive_fn_s3_test.sql` exercises the
real S3 round-trip through `pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet` -- for NDJSON, by
fetching the uploaded object back from MinIO and checking its row count directly; for Parquet, by
checking the ledger's own `s3_key`/`etag` fields rather than an independent reader round-trip. That
asymmetry is real and not yet closed: nothing in this project's current CI re-verifies a
chunked-Parquet object against pyarrow/DuckDB the way the original design's own verification (above)
did. The underlying encoder is unchanged, so there is no specific reason to expect a regression, but
it is not directly re-checked either.

## Honest limits

- **The byte budget is an estimate, not a guarantee.** It is derived from a sampled average row
  width, not the actual encoded Parquet size (which depends on the specific mix of column types
  and null density in that range). This bounds the horizon-hold to roughly the target, not an
  exact ceiling.
- **Sequence data before you regrain it.** `pgpm.regrain()`'s retention-aware skip discards (does
  not copy, does not error) any sub-range of a coarse child that already sits below the
  retention horizon -- correct and documented behavior for `regrain` on its own, but it runs
  independently of `config.archive_fn`: nothing checks archive coverage before a `regrain` swap
  discards a sub-range, only `retire()`'s own drop precondition does. Historical data that has not
  yet been chunked by this table's archiver is gone the moment `regrain` swaps it away. There is no
  standalone "archive everything now" call to run first (unlike the deleted paced worker's
  `chunk_all`) -- run `pgpm.maintain()` (or wait for its schedule) enough times to let
  `pgpm._archive_fully_covered` catch up on the coarse child's own range before regraining it.
- **Same six types, same one-row-group shape as the whole-relation encoder.** `int4`, `int8`,
  `float8`, `boolean`, `text`, `timestamp`/`timestamptz`; see [Archive partitions to
  S3](to-s3.md#honest-limits-for-the-parquet-variant) for the full list of what is out of scope
  (dictionary encoding, statistics, nested schemas, and more). NDJSON
  (`pgpm.archive_to_s3_ndjson`) has no such type restriction -- `row_to_json` round-trips any
  column type -- at the cost of not being directly queryable by a columnar analytics engine. GZIP
  is on by default for Parquet here (`archive._pq_to_parquet_range`'s `p_compress`), off by default
  for NDJSON, and its cost is not free against the byte budget either way: PR #205 measured real
  compression time from ~50ms/MB on highly compressible data up to ~2.6s/MB on near-incompressible
  data (the fixed-Huffman variant; dynamic Huffman, #206, costs somewhat more building the
  per-block code, not separately measured), and that time is part of the horizon-hold for any chunk
  that compresses, on top of the read-and-upload time the budget was already sized around. A byte
  budget picked to bound the hold at N seconds under the uncompressed assumption may run longer
  than N once compression is in the loop.
- **Parquet cannot use a per-part-commit technique, and never will.** A Parquet file's footer needs
  every row group's byte offset, known only once the whole file's bytes exist -- there is no way to
  `COMMIT` partway through building one. This is a structural fact about the format (see [Archive
  partitions to S3](to-s3.md#honest-limits-for-the-parquet-variant) and
  [#211](https://github.com/dventimisupabase/pg_partition_magician/issues/211)), not a gap; each
  Parquet chunk is always single-shot regardless of the byte budget -- which is exactly why the
  byte budget, not an internal-commit technique, is what bounds the hold here.
- **The proactive alternative (archive as soon as data freezes, not gated on retention
  eligibility) is deliberately not built here.** A child only becomes archive-eligible once it is
  both frozen and past the retention horizon (the write-block trigger's own condition), so archiving
  never runs further ahead of retention than that. A proactive variant (archive as soon as data
  freezes, regardless of retention timing) would have a real upside -- better DR/backup posture, no
  backlog pressure right at retention time -- but needs a periodic verification sweep plus a repair
  operation to correct an already-archived chunk after a late-arriving row, neither of which exists.

## Positioning

This is one archival strategy among the ones this project documents, not the only choice.
[Archive partitions to S3](to-s3.md)'s synchronous `archive.to_s3`/`archive.to_s3_parquet`
functions stay exactly as they are for anyone who does not need cross-partition chunking -- most
workloads with reasonably bounded partition sizes have no reason to reach for this. Both this
strategy's chunks and those functions' single-shot calls dispatch to the same underlying
encode/upload steps (`archive._encode_upload_ndjson_single`/`_encode_upload_parquet`), so the bytes
on the wire are identical either way; only the calling contract and the vacuum-horizon-hold shape
differ. Setting `config.archive_fn` to `pgpm.archive_to_s3_parquet` (this page's format) or
`pgpm.archive_to_s3_ndjson` is the only thing needed to use this strategy -- there is no second
schedule, gate, or drop-trigger choice to coordinate with it.
