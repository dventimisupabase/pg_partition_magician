# Chunked, cross-partition Parquet archival: bounding the horizon by file size

A third archival strategy, alongside [Archive partitions to S3](archive-to-s3.md) and
[the archive assistant](archive-assistant.md): instead of archiving one partition into one
file, this decouples Parquet files from partition boundaries entirely, so a file's size (and
therefore its vacuum-horizon hold) is a deliberate, bounded choice, never an emergent
consequence of how big a partition happened to grow. It reuses the [Parquet
encoder](archive-to-s3.md#a-columnar-variant-parquet-instead-of-ndjson) and the bytea-native
SigV4 signer from that page rather than duplicating them, and it reuses [the archive
assistant](archive-assistant.md#the-ledger-and-the-gate)'s `archive.ledger` table, derived
watermark, and gate (`archive.file_gate`, the one gate both pages now register) rather than
declaring second, near-identical copies -- deploy that page's schema section first. As of #221,
this page's own Parquet range encoder is in turn reused by the assistant (as an optional format
choice on `archive.partition`), and this page's `archive._chunk_one` can equally choose either of
the assistant's NDJSON encode/upload steps -- see [the archive
assistant](archive-assistant.md#the-archiver) for what moved where. Everything here is user-land,
like every hook and archival example in this project: pgpm ships none of it.

> **As of #222, this mechanism also ships as an installable module**: `pgpm_archive/install.sql`,
> configured per table via `archive.config` (`boundary_rule := 'byte_budget'`) instead of
> hand-editing the `c_`-prefixed constants below. This page's SQL, its names (`archive._chunk_one`,
> `archive.chunk_step`/`chunk_all`, `c_self_driving`, `c_format`, ...), and everything it verified
> are all unchanged and kept below as the design rationale; see [Choosing an archival strategy's
> name mapping](archive-strategies-overview.md#installing-the-module) for how each maps onto the
> module, and this page's own ["Install"](#install) section for the module-based install path.

## Why partition size is the wrong unit to bound

The single-PUT Parquet hook and the archive assistant both bound their vacuum-horizon hold in
terms of *partitions* (one whole partition's read+upload for the hook, one *part* of a
partition for the assistant). That is fine as long as a partition's size is itself bounded, but
under time-cut partitioning, partition size is emergent -- ingest rate x row width x interval --
not something the partitioning DDL controls at all. A busy month sitting next to a quiet one
means some partitions are ten times the size of their neighbors, and the hook's horizon-hold
grows in lockstep with whichever partition happens to be up for archiving.

The fix is not a size-aware exporter bolted onto the existing per-partition model, nor a finer
partitioning grid picked defensively for the worst case. Parquet's footer needs every row
group's byte offset known before it is written, which sounds like a per-*file* constraint tied
to a partition -- but it is really just a constraint on **whatever range of rows becomes one
file**, and nothing requires that range to line up with a partition boundary. Once a file's
size is chosen independently of the partitioning grid, the horizon-hold becomes bounded and
predictable by construction, without touching pgpm's core partitioning model and without an
external worker.

## The one invariant

For a managed parent table `P`, the set of rows covered by `archive.ledger` is always a
contiguous, non-overlapping, gap-free run of `[lo, hi)` ranges starting from wherever the ledger
starts. The **watermark** for `P` is `max(hi)` over that run, and everything below it is
guaranteed durably archived (uploaded, confirmed, ledgered). Nothing here stores a separate
cursor: the watermark is *derived* from the ledger on every read, so there is no second piece of
state that could drift out of sync with what was actually archived.

This page writes into the same `archive.ledger` table [the archive
assistant](archive-assistant.md#the-ledger-and-the-gate) does -- `lo` is the primary key, and a
file's row leaves `child_name` `null` (a chunked file's range need not equal any one partition's
bounds). `archive._file_watermark` (the derived-watermark helper) and `archive.file_gate` (the
gate itself, see below) are also defined once, on that page -- deploy its schema section first;
nothing here redeclares them, so there is only one definition of each to keep correct.
`archive._chunk_one` (below) only ever extends the watermark forward by construction, which is
what makes the fast path's plain `max(hi)` trustworthy for this page's own writes; [the archive
assistant](archive-assistant.md#the-archiver) enforces that same forward-only discipline
explicitly for its own archiver, since that one takes an arbitrary partition name rather than
always extending from the current watermark itself.

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
S3](archive-to-s3.md#a-columnar-variant-parquet-instead-of-ndjson)'s shared key-discovery helper,
reused as-is here and by [the archive assistant](archive-assistant.md#the-archiver)'s
NDJSON-with-commits range reader (#221): a PRIMARY KEY preferred, else a predicate/expression-free
UNIQUE CONSTRAINT, never a bare UNIQUE INDEX unbacked by a constraint. A genuinely keyless relation
is refused outright -- the same `'nokey'` contract `regrain()` already enforces, an inherited
limitation, not a new gap. (On a partitioned parent, Postgres itself requires any unique constraint
to include every partitioning column, so in practice the control column is always already one of
the columns this discovers.)

`archive._pq_encode_column_data` already takes the `p_order_by` parameter this range reader
needs (default `'ctid'`, so `archive._pq_to_parquet`'s whole-relation callers are unaffected
byte-for-byte) -- see its definition in [Archive partitions to
S3](archive-to-s3.md#a-columnar-variant-parquet-instead-of-ndjson). It is deliberately not
redeclared here: Postgres overload resolution is keyed on the parameter type list, not names or
defaults, so a second definition with a different arity would coexist as a distinct overload
rather than replace the original, and a 4-arg call from `archive._pq_to_parquet` would become
ambiguous between the two (#209). Install `archive-to-s3.md`'s SQL first; everything below
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
      v_page_bytes := archive._pq_gzip_compress(v_data);
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
[`prototypes/parquet-writer/`](../prototypes/parquet-writer/README.md#the-cross-partition-range-variant)
-- the standalone spike this section grew from, same as the whole-relation encoder before it.

## The gate

The archive assistant's original veto, `archive.gate` (retired in favor of this one -- see [the
archive assistant](archive-assistant.md#the-ledger-and-the-gate)), compared one child's live row
count against one recorded number. That never carried over cleanly to this page,
because one *file* can cover parts of several partitions, and the ledger records one count per
*file*, not a per-partition breakdown -- so `archive.file_gate` (defined once, on the assistant's
page, alongside the ledger and the watermark this page shares with it) replaces it everywhere,
partition-aligned or not:

1. **Fast path**: `p_hi <= watermark(p_parent)`, derived, no scan. False means the partition
   being considered is not fully archived yet -- defer.
2. **Defense in depth**: for every ledger row overlapping `[p_lo, p_hi)`, recount that
   file's *entire* range live and compare to its recorded `rows_archived`, decrementing it by the
   dropped partition's own overlap once the drop proceeds -- so a later sibling's recount compares
   against what's actually still expected to be live, not a number frozen at archive time. (This
   fixes a real misfire: dropping two partitions covered by the same file in separate `retire()`
   calls, the normal case since `retain_batch` paces drops one at a time. See the archive
   assistant's page for the full sequential-sibling-drop story and the code itself.)

The `Install` section below registers `archive.file_gate` on any table using this chunker; the
assistant's own install instructions register the identical function.

## The chunker

Each file covers `[watermark(P), stop)`, where `stop` is the smallest of three bounds:

- **Target byte budget**: translated into a row-count limit via a sampled average row width
  (the same technique `pgpm.regrain_step`'s `drain_max_blocks` path already uses), then extended
  forward to the next *distinct* control value past the sampled cutoff -- never splitting a run
  of ties across two files. If the sample runs off the live end of the table before the budget
  is reached, this bound simply does not apply.
- **Frozen floor**: the same concept `pgpm.regrain_step` computes -- the whole range at/below the
  current grid floor, so no live write can still land there per pgpm's obtain-ahead guarantee.
- **Retention horizon**: the chunker never archives further ahead than data that is already
  retention-eligible. This is the deliberate choice over a proactive alternative (archive as soon
  as data freezes, regardless of retention timing): the proactive version has a real upside
  (much better DR/backup posture, no backlog-pressure-at-retention-time), but it opens a window
  between "archived" and "actually dropped" during which a late-arriving row could land in an
  already-archived-but-still-attached partition, and this chunker is forward-only (it advances
  the watermark, never revisits an already-ledgered file) -- unlike `archive.scan()`, which
  naturally re-archives a stale child on its next pass. Bounding by retention eligibility keeps
  that window equal to the scan cadence, not calendar time, so the gate's recount is sufficient
  on its own without a separate repair operation.

`archive._chunk_one` does exactly one file's worth of work -- pick the range, dispatch to whichever
encode/upload step `c_format` configures (`'parquet'` by default, this page's original;
`'ndjson_single'` or `'ndjson_commits'` also available -- see [the archive
assistant](archive-assistant.md#the-archiver) for what each one is and does), ledger, `commit` --
so the vacuum-horizon hold for that call is bounded by the byte budget, the same way the archive
assistant bounds its hold by `c_part_bytes`, just without the assistant's per-part sub-splitting
by default (Parquet cannot sub-split at all; `'ndjson_commits'` can, if chosen here -- a small
enough file makes it unnecessary either way; see the design's positioning below).
`archive.chunk_step` is the paced, one-file-per-call entry point (a cron tick, mirroring how
`archive.scan()` is driven); `archive.chunk_all` loops it in one call until there is no more
progress (the operator's "do it now", mirroring `pgpm.regrain`'s shape). Both take a session
advisory lock distinct from the archive assistant's, so a chunker and a scanner never collide if
both are ever run against the same database.

By default this chunker is **gate-only**: it never calls `retire()` itself, leaving drop timing
entirely to `retain()`'s own schedule with `archive.file_gate` vetoing anything not yet covered.
Setting `c_self_driving := true` makes it **self-driving** instead: right after a chunk's ledger
row commits, it calls [the archive assistant](archive-assistant.md#the-scanner)'s
`archive._retire_covered(p_parent, v_hi)` -- the same shared, claim-guarded retire sweep the
assistant's own scanner uses, just handed this chunk's new watermark instead of the retention
boundary -- retiring any partition (or partitions, if one chunk happens to span several) the new
range now fully covers. `retain()`'s own schedule is still worth leaving in place even
self-driving, exactly as the assistant recommends for itself: a further-out backstop in case the
chunker wedges.

Picking the range is its own step, `archive._next_range_byte_budget`, factored out so [the archive
assistant](archive-assistant.md#the-archiver)'s own boundary rule
(`archive._next_range_partition_aligned`) can sit alongside it with a matching shape (`(p_parent)`
in, `(lo, hi)` or no rows out) -- nothing downstream of the range (the read, the encode, the
upload, the ledger write) depends on which rule picked it.

```sql
-- picks this chunker's next range: the derived watermark (or this table's own grid anchor on the
-- very first call -- reusing pgpm.config's grid origin rather than inventing a second one) up to
-- the smallest of the frozen floor, the retention horizon, and the byte-budget estimate, extended
-- to the next distinct control value so a run of ties never splits across two files. Returns no
-- rows if nothing is eligible to archive yet.
create or replace function archive._next_range_byte_budget(p_parent regclass, c_byte_budget bigint default 8 * 1024 * 1024, c_probe_sample int default 1000)
returns table(lo text, hi text)
language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_nsp name; v_rel name;
  v_lo text; v_frontier text; v_floor text; v_retain_boundary text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_bytebudget_stop text;
  v_stop text; v_hi text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._next_range_byte_budget: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  v_lo := coalesce(archive._file_watermark(p_parent), cfg.partition_anchor);

  v_frontier := pgpm._frontier_native(p_parent);
  v_floor := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);
  if not pgpm._native_gt(cfg.control_kind, v_floor, v_lo) then
    return;   -- nothing has frozen past the watermark yet
  end if;

  v_retain_boundary := pgpm._retain_boundary(cfg);
  if v_retain_boundary is not null and not pgpm._native_gt(cfg.control_kind, v_retain_boundary, v_lo) then
    return;   -- nothing retention-eligible past the watermark yet
  end if;
  v_stop := v_floor;
  if v_retain_boundary is not null and pgpm._native_gt(cfg.control_kind, v_stop, v_retain_boundary) then
    v_stop := v_retain_boundary;
  end if;

  -- byte budget -> row-count estimate, via a sampled average row width
  execute format(
    'select avg(pg_column_size(t.*))::numeric from (select * from %I.%I t where t.%I >= %L order by t.%I limit %s) t',
    v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, c_probe_sample)
    into v_avg;
  if coalesce(v_avg, 0) <= 0 then
    return;   -- nothing at/after the watermark yet
  end if;
  v_batch := greatest(1, floor(c_byte_budget::numeric / v_avg))::int;

  execute format(
    'select count(*), max(%I)::text from (select %I from %I.%I t where t.%I >= %L order by t.%I limit %s) s',
    cfg.control_column, cfg.control_column, v_nsp, v_rel, cfg.control_column,
    pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, v_batch)
    into v_batch_count, v_probe_hi_col;

  if v_batch_count < v_batch then
    v_bytebudget_stop := null;   -- reached the live end of the table: this bound does not apply
  else
    v_probe_hi := pgpm._decode(cfg.control_kind, v_probe_hi_col);
    -- extend to the next distinct value past the boundary, so hi never splits a run of ties
    execute format('select min(%I)::text from %I.%I t where t.%I > %L',
                   cfg.control_column, v_nsp, v_rel, cfg.control_column, v_probe_hi_col)
      into v_next_distinct_col;
    v_bytebudget_stop := case when v_next_distinct_col is null then null
                              else pgpm._decode(cfg.control_kind, v_next_distinct_col) end;
  end if;

  if v_bytebudget_stop is not null and pgpm._native_gt(cfg.control_kind, v_stop, v_bytebudget_stop) then
    v_stop := v_bytebudget_stop;
  end if;
  v_hi := v_stop;
  if not pgpm._native_gt(cfg.control_kind, v_hi, v_lo) then
    return;   -- no progress possible this call
  end if;

  lo := v_lo; hi := v_hi;
  return next;
end;
$$;

create or replace procedure archive._chunk_one(p_parent regclass)
language plpgsql as $$
declare
  -- deployment constants: edit these six
  c_byte_budget  bigint := 8 * 1024 * 1024;   -- target file size: the horizon-hold bound
  c_probe_sample int := 1000;
  c_format       text := 'parquet';   -- 'parquet' (default, this page's original format) |
                                       -- 'ndjson_single' | 'ndjson_commits' (needs
                                       -- docs/archive-assistant.md's encoder section deployed too)
  c_compress     boolean := true;     -- GZIP; Parquet defaults on here, NDJSON defaults off on
                                       -- the assistant's page -- counts against the byte-budget
                                       -- hold below (see "Honest limits")
  c_self_driving boolean := false;    -- false (today's only mode, still the default): gate-only --
                                       -- retain()'s own schedule drives the drop, archive.file_gate
                                       -- vetoes anything not yet covered. true: retire, right here,
                                       -- any partition this chunk's new watermark now fully covers

  v_lo text; v_hi text; v_count int;
  v_s3_key text; v_etag text; v_rows bigint;
begin
  select t.lo, t.hi into v_lo, v_hi
    from archive._next_range_byte_budget(p_parent, c_byte_budget, c_probe_sample) t;
  if v_lo is null then
    return;   -- nothing eligible to archive right now
  end if;

  if c_format = 'parquet' then
    select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
      from archive._encode_upload_parquet(p_parent, v_lo, v_hi, c_compress) t;
  elsif c_format = 'ndjson_single' then
    select t.s3_key, t.etag, t.rows_archived into v_s3_key, v_etag, v_rows
      from archive._encode_upload_ndjson_single(p_parent, v_lo, v_hi, c_compress) t;
  elsif c_format = 'ndjson_commits' then
    call archive._encode_upload_ndjson_commits(p_parent, v_lo, v_hi, c_compress, v_s3_key, v_etag, v_rows);
  else
    raise exception 'archive._chunk_one: unknown c_format %; expected parquet, ndjson_single, or ndjson_commits', c_format;
  end if;

  insert into archive.ledger (parent_table, lo, hi, s3_key, etag, rows_archived)
  values (p_parent, v_lo, v_hi, v_s3_key, v_etag, v_rows);
  commit;   -- the horizon-hold window ends here

  if c_self_driving then
    v_count := 0;
    call archive._retire_covered(p_parent, v_hi, v_count);
  end if;
end;
$$;

create or replace procedure archive.chunk_step(p_parent regclass)
language plpgsql as $$
begin
  if not pg_try_advisory_lock(hashtext('pgpm-chunked-archiver')) then return; end if;
  call archive._chunk_one(p_parent);
  perform pg_advisory_unlock(hashtext('pgpm-chunked-archiver'));
end;
$$;

create or replace procedure archive.chunk_all(p_parent regclass)
language plpgsql as $$
declare v_wm_before text; v_wm_after text; v_iter int := 0;
begin
  if not pg_try_advisory_lock(hashtext('pgpm-chunked-archiver')) then return; end if;
  loop
    v_wm_before := archive._file_watermark(p_parent);
    call archive._chunk_one(p_parent);
    v_wm_after := archive._file_watermark(p_parent);
    exit when v_wm_after is not distinct from v_wm_before;
    v_iter := v_iter + 1;
    if v_iter > 1000000 then raise exception 'archive.chunk_all: safety limit'; end if;
  end loop;
  perform pg_advisory_unlock(hashtext('pgpm-chunked-archiver'));
end;
$$;
```

`_key` is built from the native `lo` value stripped to digits only (not the raw text): a raw
native-grid value like `2000-01-01 00:00:00+00` contains a `+`, and the existing SigV4 signer
does not URL-encode the key (by design, on the assumption that keys stay unreserved-URL-clean --
see [Archive partitions to S3](archive-to-s3.md#honest-limits)); an unencoded `+` in the path
produces a real `SignatureDoesNotMatch` against S3-compatible stores, caught by trying it.

## Install

Recommended: install `pgpm_archive/install.sql` (on top of `pgpm_core`) and configure this table
via `archive.config` instead of hand-editing the constants below:

```sql
insert into archive.config (parent_table, bucket, region, endpoint, prefix, boundary_rule, drop_trigger, format, compress)
values ('public.events', 'my-archive-bucket', 'us-east-1', null, 'events/',
        'byte_budget', 'gate_only', 'parquet', true);

select pgpm.hook_register('public.events', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');
select cron.schedule('pgpm-archiver', '* * * * *', 'call archive.tick()');   -- one job, every configured table
-- or, the operator's "do it now" for just this table:
call archive.run_all('public.events'::regclass);
```

Or, build it directly from this page's SQL above (`archive._chunk_one`/`chunk_step`/`chunk_all`,
not the module's `archive._tick_one`/`archive.tick()`/`archive.run_all` -- see the [name
mapping](archive-strategies-overview.md#installing-the-module) if you're cross-referencing both):

```sql
select pgpm.hook_register('public.events', 'pre_drop', 'archive.file_gate(regclass,name,text,text)');

-- paced, one file per tick:
select cron.schedule('pgpm-chunker', '* * * * *', 'call archive.chunk_step(''public.events''::regclass)');

-- or, the operator's "do it now" (also fine as a one-off before the schedule takes over, to
-- work through an existing backlog):
call archive.chunk_all('public.events'::regclass);
```

No `retain_batch` is required for the same reason the archive assistant does not need one: the
gate is a cheap lookup (plus the bounded recount), so an unbounded `retain()` pass over an
already-archived backlog stays quick.

## Verified end-to-end, through the real `retire()` path

Driven against a live `http`-extension PostgreSQL 17 instance (built the same way the project's
own `Dockerfile` builds `pg_cron`, here for `pgsql-http`) and a real MinIO container:

- **The chunked-read invariant, at scale.** A 1,000-row, 20-day time-kind table, deliberately
  including rows with duplicate timestamps, chunked with a byte budget small enough to force
  many files per day: `archive.chunk_all` produced 57 files. Every one of the 57 was fetched
  back from MinIO and read independently by pyarrow and DuckDB; the union of all 57 files'
  content matched a direct database query over the same range exactly -- same row count, same
  ids, same order, zero duplicates, zero drops. The `[lo, hi)` ranges across all 57 rows were
  confirmed programmatically contiguous and gap-free (`lag(hi) over (order by lo)` equals the
  next `lo`, everywhere).
- **The sequential-sibling-drop correctness fix.** Constructed the exact adversarial sequence
  described above -- two partitions covered by one file, dropped one `retire()` call at a
  time -- and confirmed the naive static-recount gate misfires (a false "changed since
  archived" on the second drop) while the decrement-based gate here passes both drops cleanly,
  with the file's `rows_archived` correctly tracking down to zero as both partitions leave the
  live table.
- **A real stray, caught through the real `retire()`/`retain()` path**, not just a direct call to
  the gate: an id-kind table (5,250 rows, chunked and partially retired through `pgpm.retain()`),
  with a row deleted out of an already-archived, still-attached partition before its own drop was
  attempted. `pgpm.retain()` returned `0` dropped, and `pgpm.log` recorded the real
  `retain_hook_fail` with `archive.file_gate`'s exact message (`"... changed since it was
  archived (47 rows live, 48 archived) ..."`) verbatim -- the identical failure contract every
  other hook on this project's archival pages uses.
- **Single-writer confirmed under real concurrency**: with a second session holding
  `pg_advisory_lock(hashtext('pgpm-chunked-archiver'))`, a concurrent `archive.chunk_step` call
  correctly no-oped (watermark and file count unchanged) rather than double-archiving.
- **Both driving modes**: `archive.chunk_step` advanced the watermark by exactly one file per
  call (paced mode); `archive.chunk_all` drained a whole eligible backlog in one call and was a
  clean no-op on immediate re-invocation once nothing new had frozen.
- **Real drops through `pgpm.retain()`**, not simulated: with `archive.file_gate` registered as
  an ordinary `pre_drop` hook, retention-eligible partitions archived by the chunker were
  dropped cleanly through the standard `retain()` path, gate passing each time.
- **GZIP on, through the same real path**: a 5,000-row table (all six types including a nullable
  column) chunked with `c_compress := true` and a byte budget small enough to force many files
  produced 112 files, gap-free and contiguous by the same `lag(hi)` check above. Every column's
  page in every one of the 112 fetched objects carried Thrift `codec = GZIP`; the union of all
  112, read independently by pyarrow and DuckDB, matched the source rows exactly. `retain()`
  through the real `archive.file_gate` hook dropped the fully-covered partition cleanly and
  correctly deferred the partition its data hadn't reached the ledger watermark for yet.
- **Shared-table and shared-gate re-verification (#217, #218)**: `archive.chunk_all` writes its
  range rows into the same `archive.ledger` table [the archive
  assistant](archive-assistant.md#the-ledger-and-the-gate) uses, leaving `child_name` `null`.
  Confirmed against a second managed table archived concurrently through the assistant
  (`child_name` populated there, `archive.file_gate` registered on both): both tables' rows
  coexisted in the one table with no key collision, and `archive._file_watermark`/
  `archive.file_gate` correctly read and gated each table using only its own `[lo, hi)` ranges,
  with no cross-talk from the other table's rows sitting in the same ledger.
- **Boundary-rule extraction (#219)**: after factoring the range computation out of
  `archive._chunk_one` into `archive._next_range_byte_budget`, re-ran both fixtures above --
  `archive.chunk_all` against a single-file table and against a small-byte-budget table forced to
  334 files over 5,000 rows -- and got byte-identical results: same ranges, same row counts, same
  `lag(hi)` gap-free contiguity.
- **Self-driving mode (#220)**: with `c_self_driving := true`, one `archive.chunk_all` call
  archived a range spanning three attached partitions and retired all three immediately -- through
  the same shared `archive._retire_covered` [the archive
  assistant](archive-assistant.md#the-scanner) uses for its own retire sweep, just handed this
  chunk's watermark instead of the retention boundary. The unchanged gate-only default (`false`)
  was re-confirmed archiving without ever retiring, `retain()` picking up the drop on its own
  schedule exactly as before.

## Honest limits

- **The byte budget is an estimate, not a guarantee.** It is derived from a sampled average row
  width, not the actual encoded Parquet size (which depends on the specific mix of column types
  and null density in that range). This bounds the horizon-hold to roughly the target, the same
  spirit as the archive assistant's `c_part_bytes`, not an exact ceiling.
- **The defense-in-depth recount is more expensive than the old per-child check**, by design:
  it scans a whole file's range, which by construction can be bigger than one partition, on
  every `retire()` attempt for any partition that file covers. Named cost, not glossed over --
  see the design rationale above for why a per-file count with no per-partition breakdown was
  the chosen tradeoff.
- **Sequence data before you regrain it.** `pgpm.regrain()`'s retention-aware skip discards (does
  not copy, does not error) any sub-range of a coarse child that already sits below the
  retention horizon -- correct and documented behavior for `regrain` on its own, but it means
  historical data that has not yet been chunked by this page's archiver is gone the moment
  `regrain` swaps, with nothing to gate it (there is no partition-level `pre_drop` hook fired by
  a `regrain` swap, only by `retire`/`retain`). Run the chunker's backlog down with
  `archive.chunk_all` before regraining a coarse child that holds unarchived history.
- **Same six types, same one-row-group shape as the whole-relation encoder, when `c_format` is
  `'parquet'`**: `int4`, `int8`, `float8`, `boolean`, `text`, `timestamp`/`timestamptz`; see
  [Archive partitions to S3](archive-to-s3.md#honest-limits-for-the-parquet-variant) for the full
  list of what is out of scope (dictionary encoding, statistics, nested schemas, and more). NDJSON
  (`'ndjson_single'`/`'ndjson_commits'`) has no such type restriction -- `row_to_json` round-trips
  any column type -- at the cost of not being directly queryable by a columnar analytics engine.
  GZIP is on by default for Parquet here (`archive._pq_to_parquet_range`'s `p_compress`,
  `archive._chunk_one`'s `c_compress`), off by default for NDJSON (matching [the archive
  assistant](archive-assistant.md#the-archiver)'s own default), and its cost is not free against
  this section's byte budget either way: PR #205 measured real compression time from ~50ms/MB on
  highly compressible data up to ~2.6s/MB on near-incompressible data, and that time is now part of
  the horizon-hold for any file that compresses, on top of the read-and-upload time the budget was
  already sized around. A `c_byte_budget` picked to bound the hold at N seconds under the
  uncompressed assumption may run longer than N once compression is in the loop; set
  `c_compress := false` if the byte budget is tuned tightly enough that this matters more than the
  smaller files do.
- **Parquet cannot use `'ndjson_commits'`'s per-part-commit technique, and never will.** A
  Parquet file's footer needs every row group's byte offset, known only once the whole file's
  bytes exist -- there is no way to `COMMIT` partway through building one. This is a structural
  fact about the format (see [Archive partitions to
  S3](archive-to-s3.md#honest-limits-for-the-parquet-variant) and
  [#211](https://github.com/dventimisupabase/pg_partition_magician/issues/211)), not a gap;
  `'parquet'` is always single-shot here regardless of `c_byte_budget`.
- **The proactive alternative (archive as soon as data freezes, not gated on retention
  eligibility) is deliberately not built here.** It would need a periodic verification sweep plus
  a `repatch`-shaped repair operation to correct an already-archived file after a late-arriving
  row, neither of which exists yet. See the rationale under "The chunker" above for why bounding
  by retention eligibility avoids needing either.

## Positioning

This is a parallel strategy, not a replacement for anything else on this project's archival pages.
The single-PUT `archive.to_s3_parquet` hook stays exactly as it is for anyone who does not need
cross-partition chunking -- most workloads with reasonably bounded partition sizes have no reason
to reach for this. `archive.partition` (the archive assistant's own archiver) no longer builds its
NDJSON directly either, as of #221 -- both it and `archive._chunk_one` dispatch to the same three
`archive._encode_upload_*` steps, defined once on [the archive
assistant](archive-assistant.md#the-archiver)'s page. `archive.chunk_step` / `archive.chunk_all`
are additive on top of the shared `archive.ledger` table and gate (`archive.file_gate`, registered
by both pages' install instructions), and everything here can coexist in the same database. Mixing
the two *archivers* on one managed table -- calling both `archive.partition` and
`archive._chunk_one` against the same parent -- is not something this page tests or recommends,
even though the shared watermark and `archive.partition`'s forward-only guard would keep either
one from silently corrupting the other's coverage: pick one strategy per managed table for a
simpler operational story, one archiver and one schedule per table.
