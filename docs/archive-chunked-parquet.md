# Chunked, cross-partition Parquet archival: bounding the horizon by file size

A third archival strategy, alongside [Archive partitions to S3](archive-to-s3.md) and
[the archive assistant](archive-assistant.md): instead of archiving one partition into one
file, this decouples Parquet files from partition boundaries entirely, so a file's size (and
therefore its vacuum-horizon hold) is a deliberate, bounded choice, never an emergent
consequence of how big a partition happened to grow. It reuses the [Parquet
encoder](archive-to-s3.md#a-columnar-variant-parquet-instead-of-ndjson) and the bytea-native
SigV4 signer from that page rather than duplicating them; the per-partition `archive.ledger` /
`archive.gate` / `archive.partition` from the archive assistant are untouched and stay exactly
as they are for anyone who does not need this. Everything here is user-land, like every hook
and archival example in this project: pgpm ships none of it.

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

For a managed parent table `P`, the set of rows covered by `archive.file_ledger` is always a
contiguous, non-overlapping, gap-free run of `[lo, hi)` ranges starting from `P`'s grid anchor.
The **watermark** for `P` is `max(hi)` over that run, and everything below it is guaranteed
durably archived (uploaded, confirmed, ledgered). Nothing here stores a separate cursor: the
watermark is *derived* from the ledger on every read, so there is no second piece of state that
could drift out of sync with what was actually archived.

```sql
create schema if not exists archive;   -- if not already created for the other archival pages

create table if not exists archive.file_ledger (
  parent_table  regclass    not null,
  lo            text        not null,   -- native-grid text, same convention as pgpm.config lo/hi
  hi            text        not null,
  s3_key        text        not null,
  etag          text,
  rows_archived bigint      not null,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)        -- lo uniquely identifies a file: ranges never overlap
);
create index on archive.file_ledger (parent_table, hi desc);   -- makes max(hi) cheap

-- the derived watermark: kind-aware (numeric for id, timestamptz otherwise, matching
-- pgpm.config.control_kind), so a plain lexicographic max on the stored text never runs.
create or replace function archive._file_watermark(p_parent regclass) returns text
language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_wm text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._file_watermark: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select max(hi::%s)::text from archive.file_ledger where parent_table = %L::regclass',
                 v_ncast, p_parent::text) into v_wm;
  return v_wm;
end;
$$;
```

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
key the identical way `pgpm.regrain_step` already does (`pgpm_core/install.sql`): a PRIMARY KEY
preferred, else a predicate/expression-free UNIQUE CONSTRAINT, never a bare UNIQUE INDEX unbacked
by a constraint. A genuinely keyless relation is refused outright -- the same `'nokey'` contract
`regrain()` already enforces, an inherited limitation, not a new gap. (On a partitioned parent,
Postgres itself requires any unique constraint to include every partitioning column, so in
practice the control column is always already one of the columns this discovers.)

```sql
-- archive._pq_encode_column_data gains an optional order-by clause (default 'ctid', so
-- archive._pq_to_parquet's existing behavior is unchanged byte-for-byte). Replace the
-- version in docs/archive-to-s3.md with this one -- same function, one added parameter.
create or replace function archive._pq_encode_column_data(p_from_sql text, p_col text, p_pgtype text, p_nullable boolean, p_order_by text default 'ctid') returns bytea
language plpgsql as $$
declare
  values_payload bytea := ''::bytea;
  is_present boolean[] := '{}';
  arr_i4 int4[]; arr_i8 int8[]; arr_f8 float8[]; arr_bool boolean[]; arr_text text[]; arr_ts timestamptz[];
  present_bools boolean[] := '{}';
  i int4; n int4;
begin
  if p_pgtype = 'int4' then
    execute format('select array_agg(%I::int4 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_i4;
    n := coalesce(array_length(arr_i4,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i4[i] is not null);
      if arr_i4[i] is not null then values_payload := values_payload || archive._pq_plain_int32(arr_i4[i]); end if;
    end loop;
  elsif p_pgtype = 'int8' then
    execute format('select array_agg(%I::int8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_i8;
    n := coalesce(array_length(arr_i8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_i8[i] is not null);
      if arr_i8[i] is not null then values_payload := values_payload || archive._pq_plain_int64(arr_i8[i]); end if;
    end loop;
  elsif p_pgtype = 'float8' then
    execute format('select array_agg(%I::float8 order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_f8;
    n := coalesce(array_length(arr_f8,1),0);
    for i in 1..n loop
      is_present[i] := (arr_f8[i] is not null);
      if arr_f8[i] is not null then values_payload := values_payload || archive._pq_plain_double(arr_f8[i]); end if;
    end loop;
  elsif p_pgtype = 'bool' then
    execute format('select array_agg(%I::boolean order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_bool;
    n := coalesce(array_length(arr_bool,1),0);
    for i in 1..n loop
      is_present[i] := (arr_bool[i] is not null);
      if arr_bool[i] is not null then present_bools := present_bools || arr_bool[i]; end if;
    end loop;
    values_payload := archive._pq_plain_boolean_array(present_bools);
  elsif p_pgtype = 'text' then
    execute format('select array_agg(%I::text order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_text;
    n := coalesce(array_length(arr_text,1),0);
    for i in 1..n loop
      is_present[i] := (arr_text[i] is not null);
      if arr_text[i] is not null then values_payload := values_payload || archive._pq_plain_text(arr_text[i]); end if;
    end loop;
  elsif p_pgtype in ('timestamptz','timestamp') then
    execute format('select array_agg(%I::timestamptz order by %s) from %s', p_col, p_order_by, p_from_sql) into arr_ts;
    n := coalesce(array_length(arr_ts,1),0);
    for i in 1..n loop
      is_present[i] := (arr_ts[i] is not null);
      if arr_ts[i] is not null then
        values_payload := values_payload || archive._pq_plain_int64(round(extract(epoch from arr_ts[i]) * 1000000)::int8);
      end if;
    end loop;
  else
    raise exception 'archive._pq_encode_column_data: unsupported column type % for column %', p_pgtype, p_col;
  end if;

  if p_nullable then
    return archive._pq_definition_levels(is_present) || values_payload;
  else
    return values_payload;
  end if;
end;
$$;

-- key discovery: identical contract to pgpm.regrain_step's own v_keyidx/v_pkjoin discovery
create or replace function archive._pq_key_columns(p_relation regclass) returns name[]
language plpgsql as $$
declare v_keyidx oid; v_cols name[];
begin
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_relation and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_relation and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then return null; end if;
  select array_agg(a.attname order by k.ord) into v_cols
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;
  return v_cols;
end;
$$;

-- archive._pq_to_parquet_range: reads [p_lo, p_hi) of p_control off p_parent (typically a
-- partitioned parent), relying on Postgres's own partition pruning. p_lo/p_hi are literals
-- already typed for p_control's actual column type -- e.g. for a uuidv7-kind control column,
-- translate a pgpm native-grid (timestamptz) value via pgpm._encode first, the same way
-- pgpm.regrain_step builds its own v_lo_lit/v_hi_lit before using them.
create or replace function archive._pq_to_parquet_range(p_parent regclass, p_control name, p_lo text, p_hi text) returns bytea
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
  v_data bytea; v_page_header bytea; v_page_offset bigint;
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

  v_key_cols := archive._pq_key_columns(p_parent);
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
    v_page_header := archive._pq_build_page_header(v_num_rows::int4, length(v_data));
    v_page_offset := length(v_body);
    v_body := v_body || v_page_header || v_data;

    v_total_uncompressed := length(v_page_header) + length(v_data);
    v_column_chunks := v_column_chunks || archive._pq_build_column_chunk(
        archive._pq_build_column_metadata(v_col_ptypes[i], v_col_names[i], v_num_rows, v_total_uncompressed, v_page_offset));
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

## The two-part gate

`archive.gate` (the archive assistant's veto) compares one child's live row count against one
recorded number. That does not carry over cleanly here, because one *file* can cover parts of
several partitions, and the ledger records one count per *file*, not a per-partition breakdown.
The gate below replaces `archive.gate` for anything using this chunker (the original stays
exactly as it is for the per-partition model):

1. **Fast path**: `p_hi <= watermark(p_parent)`, derived, no scan. False means the partition
   being considered is not fully archived yet -- defer.
2. **Defense in depth**: for every `file_ledger` row overlapping `[p_lo, p_hi)`, recount that
   file's *entire* range live and compare to its recorded `rows_archived`. A mismatch anywhere
   in that file's range defers the drop, even if the actual stray landed in a sibling partition
   sharing the same file -- intentionally conservative (a shared-file-boundary stray transiently
   blocks an unrelated partition's drop until the next chunker pass re-archives it clean), and it
   fails safe rather than silently dropping something that changed.

That description is not quite the whole story, and the gap matters: a naive implementation that
just compares the live recount against the ledger's original `rows_archived` **every time**
breaks the moment two partitions covered by the same file are dropped in separate `retire()`
calls, which is the normal case (`retain_batch` paces drops one at a time; two siblings sharing
a file are rarely eligible in the same call). Drop partition A first, and partition B's *later*
check would recount the file's live range and find fewer rows than the original
`rows_archived` -- A's rows are legitimately gone now -- which is indistinguishable from a real
stray under a static comparison, and would wedge B's drop forever. Verified by constructing
exactly that sequence (two partitions in one file, dropped one call at a time): a static
recount does misfire.

The fix is to keep `rows_archived` in lockstep with reality: once a file's recount passes and a
partition's drop is about to proceed, decrement that file's `rows_archived` by exactly the
overlap between the partition being dropped and the file's range (never more, for a partition
spanning more than one file). The next check's recount then compares against what is *actually
still expected to be live*, not a number frozen at archive time. This is safe as a `pre_drop`
hook side effect: `pgpm.retire()` runs its hooks and the `DROP` inside one subtransaction (the
`EXCEPTION` block is an implicit savepoint), so if the drop fails after the gate passes, the
decrement rolls back with everything else; if it succeeds, the decrement is durable and correct.
The `for update` on the ledger rows also serializes two concurrent `retire()` calls racing on
partitions that share a file, so the decrement is never lost to a concurrent update.

```sql
create or replace function archive.file_gate(p_parent regclass, p_child name, p_lo text, p_hi text)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; v_wm text; v_nsp name; v_rel name;
  r record; v_overlap_live bigint; v_ov_lo text; v_ov_hi text; v_child_overlap bigint;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive.file_gate: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- fast path: derived, no scan
  v_wm := archive._file_watermark(p_parent);
  if v_wm is null or pgpm._native_gt(cfg.control_kind, p_hi, v_wm) then
    raise exception 'archive.file_gate: % (hi %) is not yet fully covered by the file-ledger watermark (%); deferring the drop',
      p_child, p_hi, coalesce(v_wm, '<none>');
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- defense in depth: every file_ledger row overlapping [p_lo, p_hi), whole-range recounted
  for r in
    execute format(
      'select lo, hi, rows_archived from archive.file_ledger
        where parent_table = %L::regclass and hi::%s > %L::%s and lo::%s < %L::%s
        for update',
      p_parent::text, v_ncast, p_lo, v_ncast, v_ncast, p_hi, v_ncast)
  loop
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, r.lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, r.hi))
      into v_overlap_live;
    if v_overlap_live is distinct from r.rows_archived then
      raise exception 'archive.file_gate: file % [%, %) changed since it was archived (% rows live, % archived); deferring for re-archive',
        (select s3_key from archive.file_ledger where parent_table = p_parent and lo = r.lo),
        r.lo, r.hi, v_overlap_live, r.rows_archived;
    end if;

    -- keep rows_archived in lockstep: subtract exactly the overlap between the partition about
    -- to be dropped and this file's range (a partition can span more than one file; each gets
    -- only its own slice subtracted).
    v_ov_lo := case when pgpm._native_gt(cfg.control_kind, p_lo, r.lo) then p_lo else r.lo end;
    v_ov_hi := case when pgpm._native_gt(cfg.control_kind, r.hi, p_hi) then p_hi else r.hi end;
    execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                   v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_lo),
                   cfg.control_column, pgpm._encode(cfg.control_kind, v_ov_hi))
      into v_child_overlap;
    update archive.file_ledger set rows_archived = rows_archived - v_child_overlap
      where parent_table = p_parent and lo = r.lo;
  end loop;
end;
$$;
```

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

`archive._chunk_one` does exactly one file's worth of work -- compute the range, read, encode,
PUT, ledger, `commit` -- so the vacuum-horizon hold for that call is bounded by the byte budget,
the same way the archive assistant bounds its hold by `c_part_bytes`, just without the assistant's
per-part sub-splitting (a small enough file makes that unnecessary; see the design's positioning
below). `archive.chunk_step` is the paced, one-file-per-call entry point (a cron tick, mirroring
how `archive.scan()` is driven); `archive.chunk_all` loops it in one call until there is no more
progress (the operator's "do it now", mirroring `pgpm.regrain`'s shape). Both take a session
advisory lock distinct from the archive assistant's, so a chunker and a scanner never collide if
both are ever run against the same database.

```sql
create or replace procedure archive._chunk_one(p_parent regclass)
language plpgsql as $$
declare
  -- deployment constants: edit these five
  c_bucket       text := 'my-archive-bucket';
  c_region       text := 'us-east-1';
  c_prefix       text := 'events/';
  c_endpoint     text := null;        -- null = AWS S3; an URL for S3-compatible, path prefix and all
  c_byte_budget  bigint := 8 * 1024 * 1024;   -- target file size: the horizon-hold bound
  c_probe_sample int := 1000;

  cfg pgpm.config; v_ncast text; v_nsp name; v_rel name;
  v_lo text; v_frontier text; v_floor text; v_retain_boundary text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_bytebudget_stop text;
  v_stop text; v_hi text;
  v_key_id text; v_secret text; v_key text; v_payload bytea; v_resp http_response;
  v_rows bigint; v_etag text; h http_header;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'archive._chunk_one: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- resume point: the derived watermark, or this table's own grid anchor on the very first
  -- call (the "archival floor" the invariant refers to -- reusing pgpm.config's grid origin
  -- rather than inventing a second one)
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

  select decrypted_secret into v_key_id from vault.decrypted_secrets where name = 's3_archive_access_key_id';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 's3_archive_secret_access_key';
  if v_key_id is null or v_secret is null then
    raise exception 'archive._chunk_one: credentials missing from vault';
  end if;

  v_payload := archive._pq_to_parquet_range(p_parent, cfg.control_column,
                                            pgpm._encode(cfg.control_kind, v_lo), pgpm._encode(cfg.control_kind, v_hi));
  execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                 v_nsp, v_rel, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo),
                 cfg.control_column, pgpm._encode(cfg.control_kind, v_hi))
    into v_rows;

  v_key := c_prefix || p_parent::text || '_' || regexp_replace(v_lo, '[^0-9]', '', 'g') || '.parquet';
  v_resp := archive.s3_signed_request_bytea('PUT', c_endpoint, c_bucket, c_region, v_key, '',
                                            'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);
  if v_resp.status not between 200 and 299 then
    raise exception 'archive._chunk_one: PUT of % failed: HTTP % %', v_key, v_resp.status, left(v_resp.content, 200);
  end if;
  foreach h in array v_resp.headers loop
    if lower(h.field) = 'etag' then v_etag := h.value; end if;
  end loop;

  insert into archive.file_ledger (parent_table, lo, hi, s3_key, etag, rows_archived)
  values (p_parent, v_lo, v_hi, v_key, v_etag, v_rows);
  commit;   -- the horizon-hold window ends here
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
- **Same six types, same one-row-group, no-compression shape as the whole-relation encoder**:
  `int4`, `int8`, `float8`, `boolean`, `text`, `timestamp`/`timestamptz`; see [Archive partitions
  to S3](archive-to-s3.md#honest-limits-for-the-parquet-variant) for the full list of what is out
  of scope (dictionary encoding, compression, nested schemas, and more).
- **The proactive alternative (archive as soon as data freezes, not gated on retention
  eligibility) is deliberately not built here.** It would need a periodic verification sweep plus
  a `repatch`-shaped repair operation to correct an already-archived file after a late-arriving
  row, neither of which exists yet. See the rationale under "The chunker" above for why bounding
  by retention eligibility avoids needing either.

## Positioning

This is a parallel strategy, not a replacement for anything else on this project's archival
pages. `archive.ledger` / `archive.gate` / `archive.partition` (the per-partition,
per-part-committing archive assistant) and the single-PUT `archive.to_s3_parquet` hook stay
exactly as they are for anyone who does not need cross-partition chunking -- most workloads with
reasonably bounded partition sizes have no reason to reach for this. `archive.file_ledger` /
`archive.file_gate` / `archive.chunk_step` / `archive.chunk_all` are additive: none of the
existing tables, functions, or hooks are touched, and all of them can coexist in the same
database (registering `archive.file_gate` only on the parents that use this chunker).
