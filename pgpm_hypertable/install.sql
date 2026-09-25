-- =============================================================================
-- pg_partition_magician :: from_hypertable  --  migrate a TimescaleDB hypertable
-- to a pgpm-managed native RANGE partition set.
--
-- OPTIONAL add-on, loaded ON TOP of the core (pgpm_core/install.sql) and
-- ONLY in a database where the timescaledb extension exists. It is kept out of the
-- core install so pgpm's only runtime dependency stays pg_cron.
--
-- Strategy (see from_hypertable_design.md): un-hypertable by a full COPY into a
-- plain table under the original name, then hand to transmute -- version- and
-- catalog-agnostic, which is what the deprecated Apache builds need. The copy is
-- online (source serves traffic, committed per chunk); only the cutover takes a
-- brief lock. Scope: a single time/RANGE dimension on a timestamptz, timestamp or
-- date column, migrated ON that column (p_control must be the dimension; see
-- _from_hypertable_check_dimension for why); append-only catch-up at
-- cutover. The control column's key is whatever transmute reuses -- a PRIMARY KEY
-- or UNIQUE constraint that includes it, or keyless if it has neither (the common
-- hypertable shape). Identity columns are preserved (re-established before the
-- handoff, since CREATE TABLE LIKE does not carry identity), generated columns are
-- preserved (the copy omits them from its column list and they recompute on
-- insert), and CHECK constraints, defaults, and NOT NULL are carried onto the
-- partitioned parent by transmute. Refused up front: continuous aggregates, space
-- partitioning (>1 dimension), an integer-time dimension, and a p_control that is
-- not the dimension column; transmute also refuses a nullable control column, a
-- key that excludes it, or a bare unique index.
--
-- Catch-up has two modes. By default the cutover catches up append-only: rows
-- whose control column is past the copy watermark. That is enough for time-series
-- workloads that only ever append. For workloads that UPDATE or DELETE rows during
-- the online window, pass p_track_changes => true: the copy installs an AFTER
-- INSERT/UPDATE/DELETE row trigger on the source that logs the touched key values
-- to a <rel>_pgpm_delta table, and the cutover reconciles every touched key against
-- the live source (delete-then-reinsert-from-source, which is idempotent and
-- order-independent, and subsumes the append-only catch-up). Reconciliation is by
-- the key transmute reuses (a PRIMARY KEY or UNIQUE constraint), so tracking needs a
-- key: it is refused on a keyless table. The cutover auto-detects the apparatus (the
-- delta table) rather than taking a matching flag, so the two phases cannot disagree.
--
-- NAMING: a local ending in `_q` holds text whose identifiers are already quoted, so it is
-- spliced with `%s` and `%I` would be a bug. See the note at the top of pgpm_core/install.sql;
-- scripts/check_quoted_splices.py enforces it here too.
-- =============================================================================

-- from_hypertable_disk_estimate: the approximate extra disk the online migration needs. The copy writes a
-- full second table (heap, and the indexes/identity rebuilt at cutover), so free roughly the source's
-- current on-disk size -- summed across all chunks (heap + indexes + toast) -- until the old hypertable is
-- dropped at cutover and the space is reclaimed. Callable on its own for sizing a volume ahead of time.
create or replace function pgpm.from_hypertable_disk_estimate(p_hypertable regclass)
returns bigint language plpgsql as $$
declare v_nsp name; v_rel name; v_bytes bigint;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  select coalesce(sum(pg_total_relation_size(format('%I.%I', chunk_schema, chunk_name)::regclass)), 0)
    into v_bytes
    from timescaledb_information.chunks
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  return v_bytes;
end $$;

-- from_hypertable_time_estimate: a ROUGH order-of-magnitude estimate of the online-copy duration -- the
-- dominant cost of migrating a hypertable. (transmute on a plain table is metadata-only and takes seconds
-- regardless of size, but a hypertable's rows must be physically copied out, which is O(rows).) The copy
-- reads every chunk and writes a second heap, so the time is governed by data volume and effective
-- throughput, which is REGIME-dependent: a working set that fits in cache copies far faster than one that
-- is heap-random-I/O bound. p_copy_mibps overrides the assumed effective throughput (MiB/s of logical data
-- copied); when null it is chosen by comparing the estimated size to effective_cache_size. The defaults
-- (~40 MiB/s cache-resident, ~16 MiB/s disk-bound) are order-of-magnitude figures measured on a Supabase
-- 2XL on gp3 and scale with RAM/IOPS/throughput. This covers ONLY the copy -- the cutover's index rebuild
-- and an optional later regrain are additional. Callable on its own for sizing.
create or replace function pgpm.from_hypertable_time_estimate(
  p_hypertable regclass, p_copy_mibps numeric default null
) returns interval language plpgsql as $$
declare v_bytes bigint; v_cache bigint; v_mibps numeric;
begin
  v_bytes := pgpm.from_hypertable_disk_estimate(p_hypertable);
  v_mibps := p_copy_mibps;
  if v_mibps is null then
    begin v_cache := pg_size_bytes(current_setting('effective_cache_size'));
    exception when others then v_cache := null; end;
    v_mibps := case when v_cache is not null and v_bytes > v_cache then 16 else 40 end;
  end if;
  if v_mibps <= 0 then v_mibps := 16; end if;   -- guard against a nonsensical override
  return make_interval(secs => (v_bytes / (v_mibps * 1048576.0))::double precision);
end $$;

-- _from_hypertable_check_dimension: the two facts the chunk-by-chunk copy silently depends on (issue #458).
-- The copy bounds each chunk with `<p_control> >= range_start and < range_end` read from
-- timescaledb_information.chunks. Those are ranges OF THE DIMENSION COLUMN, and they are populated only for a
-- timestamp-typed dimension: an integer dimension's bounds live in range_start_integer and range_start is
-- NULL for every chunk. So the predicate partitions the table exactly when p_control IS the time dimension
-- AND the dimension is timestamptz/timestamp/date. Anything else copies a strict subset of the rows, or
-- nothing at all (`t >= NULL and t < NULL`), and the cutover then drops the hypertable and reports success
-- over an empty table: no error, no log row. Preflight used to check only that the column exists.
--
-- Factored out of the preflight so the cutover can run it in its own right. The cutover is the irreversible
-- step and required only that a destination exist, which a copy run under an older version (or a table made
-- by hand) satisfies without the copy phase ever having refused. dimension_number = 1 rather than
-- dimension_type = 'Time': Timescale allows a second range dimension, and then 'Time' names two rows while
-- the primary is always number 1 (preflight refuses >1 dimensions anyway). Internal, so no promise attaches.
create or replace function pgpm._from_hypertable_check_dimension(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_dim_col name; v_dim_type regtype;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  select column_name, column_type into v_dim_col, v_dim_type
    from timescaledb_information.dimensions
   where hypertable_schema = v_nsp and hypertable_name = v_rel and dimension_number = 1;
  if v_dim_col is null then
    raise exception 'pg_partition_magician: % is not a hypertable', p_hypertable;
  end if;
  if v_dim_col <> p_control then
    raise exception 'pg_partition_magician: cannot migrate hypertable % on column % -- its time dimension is %. The online copy is bounded chunk by chunk on the dimension''s chunk ranges, so it conserves rows only when p_control is the dimension column; on any other column rows would be silently lost. Pass p_control => %.',
      p_hypertable, p_control, v_dim_col, quote_ident(v_dim_col);
  end if;
  if v_dim_type not in ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype) then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- its time dimension % is %: integer-time hypertables are not supported by from_hypertable; only timestamptz, timestamp and date dimensions are. An integer dimension''s chunk ranges live in range_start_integer, which the chunk-by-chunk copy does not read, so the copy would move nothing, and the handoff to transmute is by time interval.',
      p_hypertable, v_dim_col, v_dim_type;
  end if;
end $$;

-- from_hypertable_preflight: the refusal checks, factored out so they are callable on their own (a
-- dry-run gate) and unit-testable inside a transaction. Raises a pgpm-prefixed error on any blocker;
-- returns normally when the hypertable is migratable by this version (with a NOTICE estimating the disk).
create or replace function pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare
  v_nsp name; v_rel name; v_cagg text; v_dims int; v_ctl_attnum int; v_bytes bigint;
  v_cache bigint; v_mibps numeric; v_regime text; v_eta interval;
  v_bad_fk text; v_reusekey text[]; v_fk record;
begin
  if not exists (select 1 from pg_extension where extname = 'timescaledb') then
    raise exception 'pg_partition_magician: from_hypertable requires the timescaledb extension to be installed';
  end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  if not exists (select 1 from timescaledb_information.hypertables
                  where hypertable_schema = v_nsp and hypertable_name = v_rel) then
    raise exception 'pg_partition_magician: % is not a hypertable', p_hypertable;
  end if;

  -- (1) continuous aggregates: no native-partition equivalent, and dropping them is data-destructive.
  select string_agg(view_name, ', ') into v_cagg from timescaledb_information.continuous_aggregates
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  if v_cagg is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- it has continuous aggregate(s) (%), which have no native-partition equivalent. Drop them first if you do not need them, then re-run from_hypertable.',
      p_hypertable, v_cagg;
  end if;

  -- (2) more than one dimension (space partitioning via add_dimension): pgpm is single-key RANGE.
  select num_dimensions into v_dims from timescaledb_information.hypertables
   where hypertable_schema = v_nsp and hypertable_name = v_rel;
  if coalesce(v_dims, 1) > 1 then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- it has % dimensions (space partitioning). pgpm is single-key RANGE; drop the extra dimension(s) first.',
      p_hypertable, v_dims;
  end if;

  -- (3) the control column must exist. The key/NOT-NULL contract is left to transmute (the single source
  -- of truth): it reuses a primary key or unique constraint if one includes the control column, and
  -- otherwise partitions the table keyless -- which is exactly the common hypertable shape, since
  -- create_hypertable makes the time column NOT NULL but adds no key. So a keyless hypertable migrates.
  select a.attnum into v_ctl_attnum
    from pg_attribute a where a.attrelid = p_hypertable and a.attname = p_control and not a.attisdropped;
  if v_ctl_attnum is null then
    raise exception 'pg_partition_magician: column % not found on %', p_control, p_hypertable;
  end if;

  -- (3b) ...and it must BE the time dimension, and that dimension must be a timestamp type (issue #458).
  -- Existence is not enough: a second time column passes (3) and migrates to zero rows, because the copy is
  -- bounded on the DIMENSION's chunk ranges; an integer dimension passes (3) and copies nothing, because its
  -- ranges are not in the column the copy reads. See _from_hypertable_check_dimension.
  perform pgpm._from_hypertable_check_dimension(p_hypertable, p_control);

  -- (4) an outgoing FK the source never validated (issue #264). The migration carries outgoing FKs by
  -- replaying each definition verbatim on the private destination and then VALIDATEing it, so a NOT VALID
  -- constraint would either fail that validation on pre-existing violations or be silently strengthened
  -- into a validated one. Neither is ours to decide, so refuse and name it.
  select string_agg(conname, ', ') into v_bad_fk
    from pg_constraint
   where conrelid = p_hypertable and contype = 'f' and confrelid <> p_hypertable and not convalidated;
  if v_bad_fk is not null then
    raise exception 'pg_partition_magician: cannot migrate hypertable % -- its outgoing foreign key(s) (%) are NOT VALID. from_hypertable carries an outgoing key by replaying it on the copy and validating it, which would either fail on the rows the source never checked or silently upgrade the constraint. Run ALTER TABLE % VALIDATE CONSTRAINT <name> first (or drop the constraint), then re-run from_hypertable.',
      p_hypertable, v_bad_fk, p_hypertable::text;
  end if;

  -- (5) an INCOMING FK that does not reference the key transmute will reuse (issue #264). The migration
  -- re-adds each incoming FK against the new partitioned parent, which can only carry a unique key on
  -- exactly the columns transmute reused. Refusing HERE is the single most valuable check in this
  -- function: the alternative is discovering it in the cutover, after the entire online copy has run,
  -- with the populated destination left orphaned behind the rollback.
  --
  -- The reused-key selection mirrors _transmute's, which stays the single source of truth: the PK if it
  -- includes the control column, otherwise a non-partial, non-expression UNIQUE constraint that does.
  -- Drift can only cost a MISSED refusal here, never a false one, because transmute re-checks eligibility
  -- itself -- so this check is allowed to be the more permissive of the two, never the stricter.
  if exists (select 1 from pg_constraint
              where confrelid = p_hypertable and contype = 'f' and conrelid <> p_hypertable) then
    select array_agg(a.attname::text order by k.ord) into v_reusekey
      from pg_constraint con
      cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = p_hypertable and con.contype = 'p' and v_ctl_attnum = any(con.conkey)
     group by con.conname;

    if v_reusekey is null then
      select cols into v_reusekey from (
        select array_agg(a.attname::text order by k.ord) as cols, con.conname
          from pg_constraint con
          join pg_index i on i.indexrelid = con.conindid
          cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
          join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
         where con.conrelid = p_hypertable and con.contype = 'u'
           and i.indpred is null and i.indexprs is null and v_ctl_attnum = any(con.conkey)
         group by con.conname order by con.conname limit 1) s;
    end if;

    for v_fk in
      select c.conname, c.conrelid::regclass as referencing,
             (select array_agg(a.attname::text order by k.ord)
                from unnest(c.confkey) with ordinality as k(attnum, ord)
                join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
        from pg_constraint c
       where c.confrelid = p_hypertable and c.contype = 'f' and c.conrelid <> p_hypertable
         and c.conparentid = 0
    loop
      if v_reusekey is null
         or (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            is distinct from (select array_agg(x order by x) from unnest(v_reusekey) x) then
        raise exception 'pg_partition_magician: cannot migrate hypertable % -- the incoming foreign key % on % references (%), but the key pgpm would reuse is %. An incoming key can only be re-added against the new partitioned parent when it references exactly that reused key. Drop the foreign key, or give % a primary key or unique constraint on (%) that includes the control column %, then re-run from_hypertable.',
          p_hypertable, v_fk.conname, v_fk.referencing, array_to_string(v_fk.rcols, ', '),
          coalesce('(' || array_to_string(v_reusekey, ', ') || ')', 'none (the table would be partitioned keyless)'),
          p_hypertable::text, array_to_string(v_fk.rcols, ', '), quote_ident(p_control);
      end if;
    end loop;
  end if;

  -- disk: the online copy writes a full second table, so warn how much extra space the migration needs until
  -- cutover drops the old hypertable. Informational (a NOTICE), never a refusal.
  v_bytes := pgpm.from_hypertable_disk_estimate(p_hypertable);
  raise notice 'pg_partition_magician: from_hypertable will copy % into a second table before cutover (about %); ensure that much free disk until the old hypertable is dropped at cutover and the space is reclaimed.',
    p_hypertable, pg_size_pretty(v_bytes);

  -- time: a rough ETA for the online copy (the dominant cost). The regime is guessed from
  -- effective_cache_size; both are order-of-magnitude. Informational, never a refusal.
  begin v_cache := pg_size_bytes(current_setting('effective_cache_size'));
  exception when others then v_cache := null; end;
  if v_cache is not null and v_bytes > v_cache then v_mibps := 16; v_regime := 'disk-bound: estimated size exceeds effective_cache_size';
  else v_mibps := 40; v_regime := 'cache-resident: estimated size fits effective_cache_size'; end if;
  v_eta := pgpm.from_hypertable_time_estimate(p_hypertable, v_mibps);
  raise notice 'pg_partition_magician: estimated online copy time ~ % (% at ~% MiB/s, %). This covers the copy only -- the cutover then rebuilds the primary key and secondary indexes (extra, scales with row count) and a later regrain (if used) is a similar second pass. Rough (measured on a 2XL gp3): more RAM/IOPS/throughput is faster. Override the rate with pgpm.from_hypertable_time_estimate(table, mibps).',
    v_eta, pg_size_pretty(v_bytes), v_mibps, v_regime;
end $$;

-- from_hypertable runs in two phases, exposed as separate procedures so writes can keep arriving between
-- them: from_hypertable_copy does the online bulk copy to a watermark, then from_hypertable_cutover catches
-- up the rows that arrived after it, swaps the copy into place, and hands off to transmute. from_hypertable
-- runs both back to back for the one-shot case. All are procedures because the copy commits per chunk
-- (bounded WAL/txn on a large table) and the cutover commits the swap.

-- Phase 1: build the plain destination and bulk-copy the existing chunks into it, online. The source keeps
-- serving traffic (new appends are caught up by the cutover). Leaves <rel>_pgpm_dest populated; the copy
-- watermark is implicitly max(control) in the destination.
create or replace procedure pgpm.from_hypertable_copy(
  p_hypertable regclass, p_control name, p_track_changes boolean default false
)
language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; r record;
  v_delta name; v_trgfn name; v_trg name; v_keyidx oid; v_keycols_q text; v_newvals_q text; v_oldvals_q text;
  v_keyconname name; v_keytmp text;
  v_ctl_typid regtype; v_bound_tpl text; v_lo text; v_hi text;
begin
  perform pgpm.from_hypertable_preflight(p_hypertable, p_control);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into

  -- The chunk-bound rendering for the dimension's type (see the chunk loop below for why each form is what
  -- it is). Resolved and refused HERE, before anything commits: the tracking apparatus and the destination
  -- skeleton both commit, and a refusal after either would strand an empty <rel>_pgpm_dest for the cutover
  -- to find and rename into place.
  select a.atttypid into v_ctl_typid
    from pg_attribute a where a.attrelid = p_hypertable and a.attname = p_control and not a.attisdropped;
  v_bound_tpl := case v_ctl_typid
    when 'timestamp with time zone'::regtype    then '%L::timestamptz'
    when 'timestamp without time zone'::regtype then '(%L::timestamptz at time zone ''UTC'')'
    when 'date'::regtype                        then '(%L::timestamptz at time zone ''UTC'')::date'
  end;
  if v_bound_tpl is null then
    raise exception 'pg_partition_magician: from_hypertable_copy(%) cannot bound the chunk copy on dimension % of type %: only timestamptz, timestamp and date dimensions are supported',
      p_hypertable, p_control, v_ctl_typid;
  end if;

  -- change tracking (p_track_changes): install an AFTER-ROW trigger on the source BEFORE the copy reads
  -- anything, so every insert/update/delete during the online window is logged by its key into a delta
  -- table. The cutover reconciles those keys against the live source. Reconciliation is by key, so this
  -- needs a key -- the same one transmute reuses: the PRIMARY KEY, else a UNIQUE constraint. A keyless
  -- table has no key to reconcile by, so tracking is refused (rather than silently losing updates/deletes).
  if p_track_changes then
    select coalesce(
             (select i.indexrelid from pg_index i where i.indrelid = p_hypertable and i.indisprimary limit 1),
             (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
               where con.conrelid = p_hypertable and con.contype = 'u'
                 and i.indpred is null and i.indexprs is null limit 1))
      into v_keyidx;
    if v_keyidx is null then
      raise exception 'pg_partition_magician: from_hypertable_copy(%, p_track_changes => true) needs a key to reconcile changes by, but the table has no primary key or unique constraint. Drop p_track_changes to migrate it append-only, or add a key first.',
        p_hypertable;
    end if;
    -- the key columns, and the NEW./OLD. value lists the trigger logs, in key order
    select string_agg(quote_ident(a.attname), ', ' order by k.ord),
           string_agg('new.' || quote_ident(a.attname), ', ' order by k.ord),
           string_agg('old.' || quote_ident(a.attname), ', ' order by k.ord)
      into v_keycols_q, v_newvals_q, v_oldvals_q
      from pg_index i
      cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indexrelid = v_keyidx;

    -- Reconciliation matches keys with a row-constructor IN, which never matches a NULL component -- so a
    -- key row with a NULL in any non-control key column could never be reconciled and its change would be
    -- silently lost (both online and under the lock). PK columns are NOT NULL, but a reused UNIQUE key may
    -- have nullable columns; refuse tracking up front rather than lose changes.
    if exists (select 1 from pg_index i
                 cross join lateral unnest(i.indkey) as k(attnum)
                 join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
                where i.indexrelid = v_keyidx and not a.attnotnull and a.attname <> p_control) then
      raise exception 'pg_partition_magician: from_hypertable_copy(%, p_track_changes => true) cannot track by a key with a nullable column -- a NULL key component can never be reconciled (the change would be lost). Add NOT NULL to the key column(s), or drop p_track_changes to migrate append-only.',
        p_hypertable;
    end if;

    v_delta := v_rel || '_pgpm_delta';
    v_trgfn := v_rel || '_pgpm_delta_fn';
    v_trg   := v_rel || '_pgpm_delta_trg';
    execute format('drop table if exists %I.%I', v_nsp, v_delta);
    -- delta holds just the key columns (their types come from the source via WITH NO DATA)
    execute format('create table %I.%I as select %s from %I.%I with no data',
                   v_nsp, v_delta, v_keycols_q, v_nsp, v_rel);
    -- Append a monotonic ordering column (highest attnum) so the online delta-drain (from_hypertable_drain_delta,
    -- issue #170) can batch by a pgpm_seq watermark: a batch processes+deletes rows with pgpm_seq <= watermark,
    -- and any change that arrives mid-batch lands at a higher seq for the next pass. The cutover's key
    -- introspection EXCLUDES pgpm_seq by name so it is not mistaken for a key column; the trigger inserts only
    -- the key columns (by an explicit list), so identity auto-populates pgpm_seq. Indexed so the watermark
    -- offset/limit and the range delete are index-assisted at scale.
    execute format('alter table %I.%I add column pgpm_seq bigint generated always as identity', v_nsp, v_delta);
    execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);
    -- the trigger body is dollar-quoted with a pgpm tag; the format template is single-quoted (inner quotes
    -- doubled) to avoid nesting another dollar-quoted string inside this procedure body.
    execute format('create or replace function %I.%I() returns trigger language plpgsql as $pgpm$
      begin
        if tg_op = ''DELETE'' then
          insert into %I.%I (%s) values (%s); return old;
        elsif tg_op = ''UPDATE'' then
          insert into %I.%I (%s) values (%s), (%s); return new;   -- old + new: a key change dirties both
        else
          insert into %I.%I (%s) values (%s); return new;
        end if;
      end $pgpm$',
      v_nsp, v_trgfn,
      v_nsp, v_delta, v_keycols_q, v_oldvals_q,
      v_nsp, v_delta, v_keycols_q, v_oldvals_q, v_newvals_q,
      v_nsp, v_delta, v_keycols_q, v_newvals_q);
    execute format('drop trigger if exists %I on %I.%I', v_trg, v_nsp, v_rel);
    execute format('create trigger %I after insert or update or delete on %I.%I for each row execute function %I.%I()',
                   v_trg, v_nsp, v_rel, v_nsp, v_trgfn);
    commit;   -- the apparatus must survive the phase boundary (copy commits, cutover reads the delta)
  end if;

  -- destination skeleton: structure but no indexes/key, so the bulk load maintains no per-row index.
  execute format('drop table if exists %I.%I', v_nsp, v_dest);
  execute format('create table %I.%I (like %I.%I including defaults including constraints including generated including comments)',
                 v_nsp, v_dest, v_nsp, v_rel);
  commit;

  -- online chunk-bounded copy: one chunk-range per transaction (the time predicate drives chunk exclusion
  -- to a single-chunk read; ORDER BY the control column clusters the destination for cheap transmute/regrain
  -- later). The source keeps serving traffic throughout.
  --
  -- The bounds are rendered in the dimension's OWN type (#459). timescaledb_information.chunks shows every
  -- time dimension's range_start/range_end as timestamptz: the slice's raw microseconds handed to
  -- _timescaledb_functions.to_timestamp(bigint), for a timestamp (no tz) or date dimension exactly as for a
  -- timestamptz one. Spliced with a bare %L, that instant rendered in the SESSION TimeZone
  -- ('2024-01-01 09:00:00+09' under Asia/Tokyo) and, coerced to a timestamp column, DROPPED the offset, so
  -- every chunk range shifted by the UTC offset. East of UTC the oldest chunk's first N hours fell below the
  -- union of the ranges and no chunk copied them, and the cutover's > max(dest) catch-up cannot reach rows
  -- below its watermark, so they were gone after the migration. West of UTC the last chunk's tail was missed
  -- and rescued by the catch-up only by accident, and a date dimension lost its last day.
  --   timestamptz  %L::timestamptz                            the literal carries its offset, so it is exact
  --   timestamp    (%L::timestamptz at time zone 'UTC')       the view is the raw value rendered AS a UTC
  --                                                           instant (to_timestamp_without_timezone is the
  --                                                           same C function with a timestamp result), so
  --                                                           converting back AT UTC returns the exact
  --                                                           wall-clock value the chunk's own CHECK names
  --   date         (%L::timestamptz at time zone 'UTC')::date the same, to the day
  -- Verified against pg_get_constraintdef of the chunk's dimension CHECK. Each is a constant expression, so
  -- the planner still folds it and excludes the other chunks. Any other dimension type has a NULL
  -- range_start in the view (an integer dimension reports range_start_integer instead), and the old
  -- predicate would have copied nothing at all; v_bound_tpl was resolved, and such a dimension refused,
  -- up top before anything committed.
  for r in select range_start, range_end from timescaledb_information.chunks
            where hypertable_schema = v_nsp and hypertable_name = v_rel order by range_start loop
    v_lo := format(v_bound_tpl, r.range_start);
    v_hi := format(v_bound_tpl, r.range_end);
    execute format('insert into %I.%I (%s) select %s from %I.%I where %I >= %s and %I < %s order by %I',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel,
                   p_control, v_lo, p_control, v_hi, p_control);
    commit;
  end loop;
  -- The destination was just CREATE TABLE LIKE'd and bulk-loaded, so it has no planner stats (reltuples=0).
  -- ANALYZE it now -- while it is still private and unlocked -- so the cutover's delta reconcile plans
  -- against the real row count. Without this the planner thinks the dest is empty and seqscans the whole
  -- table for the reconcile, making the (locked) cutover O(rows) instead of O(delta). pgpm._analyze is the
  -- core's shared mint-then-populate ANALYZE helper (#164).
  perform pgpm._analyze(format('%I.%I', v_nsp, v_dest)::regclass);
  commit;

  -- OUTGOING foreign keys (issue #264). `CREATE TABLE ... LIKE ... INCLUDING CONSTRAINTS` copies CHECK and
  -- NOT NULL only -- no INCLUDING option copies foreign keys -- and nothing later added them, so the source
  -- hypertable was the only relation still holding them and the cutover DROPS it. The migration therefore
  -- used to lose referential integrity silently: no error, nothing in pgpm.log, and orphan rows accepted
  -- afterwards in every partition.
  --
  -- Replayed VERBATIM from pg_get_constraintdef, which carries composite keys, referential actions and
  -- DEFERRABLE-ness without pgpm having to reason about any of them. The destination reaches the cutover
  -- holding a VALIDATED key, so the swap stays metadata-only and the parent-level ADD adopts it.
  --
  -- Two steps in two transactions, and this is the reason the work lives HERE rather than in the cutover: a
  -- validating ADD CONSTRAINT ... FOREIGN KEY holds SHARE ROW EXCLUSIVE on the REFERENCED table for the
  -- whole scan, blocking writes on a table the operator did not ask us to lock. Splitting it means
  -- VALIDATE holds only SHARE UPDATE EXCLUSIVE here and ROW SHARE there, so the referenced table stays
  -- writable. The cutover could not do this at all: its pre-build block shares one transaction with the
  -- swap, so the lock would span the swap. O(rows) work belongs in the copy phase, which is exactly why
  -- the index pre-build lives here too.
  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = p_hypertable and c.contype = 'f' and c.confrelid <> p_hypertable
     order by c.conname
  loop
    execute format('alter table %I.%I add constraint %I %s not valid', v_nsp, v_dest, r.conname, r.def);
    commit;
    execute format('alter table %I.%I validate constraint %I', v_nsp, v_dest, r.conname);
    commit;
    insert into pgpm.log (parent_table, action, method)
      values (p_hypertable, 'from_hypertable_carry_fk', r.conname);
  end loop;

  -- #175: when change-tracking is on, build the reused-key index on the dest NOW -- off the lock, while the
  -- dest is still private -- with the SAME temp name and definition the cutover will ADOPT
  -- (left(conname || '_pgpm_new', 63), via pg_get_indexdef). The online delta drain then uses it for its
  -- per-batch key lookups (no separate throwaway index), and the cutover adopts it instead of rebuilding it
  -- -- one key-index build instead of two. (v_keyidx was chosen above for tracking; tracking is refused on a
  -- keyless table, so it is always set here.)
  if p_track_changes then
    select conname into v_keyconname from pg_constraint where conindid = v_keyidx;
    v_keytmp := left(v_keyconname || '_pgpm_new', 63);
    execute regexp_replace(pg_get_indexdef(v_keyidx),
      '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+',
      '\1' || quote_ident(v_keytmp) || ' ON ' || quote_ident(v_nsp) || '.' || quote_ident(v_dest));
    commit;
  end if;
end $$;

-- Online delta drain (issue #170): reconcile the change-capture delta in bounded micro-batches WHILE the
-- source stays live, BEFORE the cutover takes its lock, so the locked window applies only a tiny residual
-- instead of the whole online-copy backlog. The reconcile is idempotent and order-independent per key (drop
-- the key's copied row from the dest, reinsert its current source row -- a deleted key stays absent, an
-- updated key gets its current value, an inserted key appears), which is exactly what makes incremental
-- draining safe: partial progress is always consistent, and any key can be reconciled more than once with no
-- effect. New writes keep appending to the delta during the drain; we chase the backlog down. The final
-- (tiny) residual is applied by the cutover under the brief lock, which is the correctness backstop.

-- from_hypertable_drain_delta_step does ONE micro-batch (no commit; the driver commits per batch). It
-- delete-RETURNS the batch's distinct keys from the delta as the authority and reconciles EXACTLY those keys
-- against the live source: a key the batch does not see (e.g. a write still in flight) is simply left in the
-- delta for the next batch or the under-lock final reconcile, so a change is never deleted-without-applying
-- (the read-then-delete race a two-snapshot approach would have). The batch is bounded by a pgpm_seq
-- watermark; the source read is bounded to the batch's control [min,max] as literal constants so TimescaleDB
-- excludes untouched chunks -- per-batch, even tighter than the one-shot reconcile (#166). Returns the number
-- of distinct keys reconciled this batch (0 = the delta is empty).
create or replace function pgpm.from_hypertable_drain_delta_step(
  p_hypertable regclass, p_control name, p_batch int default 5000
) returns bigint language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_delta name;
  v_keycols_q text; v_dkey_q text; v_skey_q text; v_cols_q text;
  v_ctl_type text; v_min_ctl text; v_max_ctl text; v_watermark bigint; v_keys bigint;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  v_delta := v_rel || '_pgpm_delta';
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_delta_step(%) found no delta -- change tracking was not enabled by from_hypertable_copy', p_hypertable;
  end if;

  -- key columns = every delta column EXCEPT the pgpm_seq ordering column, in attnum order (the same order
  -- the cutover uses, so the row constructors line up). d./s. variants for the dest delete + source insert.
  select string_agg(quote_ident(attname), ', ' order by attnum),
         '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
         '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')'
    into v_keycols_q, v_dkey_q, v_skey_q
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- the source/dest column list for the reinsert (generated columns omitted: they recompute on insert)
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';

  -- the dest's per-batch delete uses the reused-key index that from_hypertable_copy built on the dest (#175,
  -- the same index the cutover adopts); no separate throwaway index is built here.

  -- batch boundary: the pgpm_seq of the p_batch-th oldest delta row (or max when fewer remain)
  execute format('select coalesce((select pgpm_seq from %I.%I order by pgpm_seq offset %s limit 1), (select max(pgpm_seq) from %I.%I))',
                 v_nsp, v_delta, greatest(p_batch - 1, 0), v_nsp, v_delta) into v_watermark;
  if v_watermark is null then return 0; end if;   -- delta empty

  -- materialize this batch's distinct keys authoritatively by DELETING them: delete-returning is the source
  -- of truth, so we reconcile exactly what we removed (no delete-without-apply race). on commit drop: the
  -- driver commits after each batch (dropping it), a standalone call drops it at autocommit; the drop-if-
  -- exists first guards the rare same-transaction re-call.
  execute 'drop table if exists pgpm_dbatch';
  execute format('create temp table pgpm_dbatch on commit drop as
                  with d as (delete from %I.%I where pgpm_seq <= %s returning %s)
                  select distinct %s from d',
                 v_nsp, v_delta, v_watermark, v_keycols_q, v_keycols_q);
  get diagnostics v_keys = row_count;

  -- bound the source read to the batch's touched control range, as literal constants, for chunk exclusion
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  execute format('select min(%I)::text, max(%I)::text from pgpm_dbatch', p_control, p_control)
    into v_min_ctl, v_max_ctl;

  -- reconcile: drop the batch's keys from the dest, then reinsert their current source rows
  execute format('delete from %I.%I d where %s in (select %s from pgpm_dbatch)', v_nsp, v_dest, v_dkey_q, v_keycols_q);
  if v_min_ctl is not null then
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch) and %I >= %L::%s and %I <= %L::%s',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_keycols_q,
                   p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type);
  else
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch)',
                   v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_keycols_q);
  end if;
  return v_keys;
end $$;

-- from_hypertable_drain_delta loops the step with a per-batch COMMIT (so WAL recycles -- the same reason
-- from_hypertable_copy commits per chunk), mirroring drain_all's _step + _all shape. It chases the backlog
-- down until the residual is at/below p_threshold (0 = drain to empty), tested cheaply with an EXISTS at
-- offset (like drain_step's EXISTS-not-count). Under sustained write load the residual may never reach the
-- threshold; p_max_iter bounds the loop -- it raises a loud, actionable error UNLESS p_best_effort, in which
-- case it returns so the caller (the cutover) can take the lock and finish the now-smaller residual under it.
-- The per-batch dest delete uses the reused-key index from_hypertable_copy built on the dest (#175) -- the
-- same index the cutover adopts -- so the drain builds no index of its own.
create or replace procedure pgpm.from_hypertable_drain_delta(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_delta name;
  v_iter int := 0; v_more boolean;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  v_delta := v_rel || '_pgpm_delta';
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_delta(%) found no delta -- change tracking was not enabled by from_hypertable_copy', p_hypertable;
  end if;

  loop
    -- residual <= threshold? EXISTS at offset stops at the first row past the threshold (count > threshold)
    execute format('select exists(select 1 from %I.%I order by pgpm_seq offset %s limit 1)',
                   v_nsp, v_delta, p_threshold) into v_more;
    exit when not v_more;
    perform pgpm.from_hypertable_drain_delta_step(p_hypertable, p_control, p_batch);
    commit;
    v_iter := v_iter + 1;
    if v_iter > p_max_iter then
      if p_best_effort then return; end if;
      raise exception 'pg_partition_magician: from_hypertable_drain_delta(%) did not converge within % iterations -- the workload is dirtying keys faster than the drain clears them. Raise p_batch, raise p_threshold to accept a larger final cutover batch, or pause writes before cutting over.',
        p_hypertable, p_max_iter;
    end if;
  end loop;
end $$;

-- Append-only online pre-drain (issue #174). The non-tracking catch-up (the cutover's append-only branch)
-- copies every row appended past the copy watermark, which grows with the copy duration -- so the locked
-- window grows with the migration, the same wound #170 closed for the tracking path. Pre-drain that tail
-- ONLINE, in bounded batches that advance the watermark, so the locked catch-up applies only the final tail.
-- Simpler than the delta drain: append-only means already-copied rows never change, so it is purely additive
-- -- no delta, no reconcile, no key, no dest index, and no race (the watermark marches forward; an append
-- that lands mid-batch has a higher control value and is taken next pass). It assumes the append-only
-- contract (no updates/deletes to copied rows, and appends arriving in control order), exactly as the
-- under-lock catch-up already does -- use p_track_changes for update/delete workloads and for any
-- workload that can append out of order. What arrives behind the watermark is invisible here and to the
-- under-lock catch-up alike; the cutover's conservation check (#460) refuses the swap rather than lose it.

-- from_hypertable_drain_appends_step copies ONE batch of appends past p_watermark and returns the new
-- watermark (the batch's upper control bound, as text); no commit (the driver commits per batch). The batch
-- is bounded to ~p_batch rows by the control value p_batch rows past the watermark, INCLUSIVE of ties at that
-- bound (a row-count LIMIT with a strict > would drop ties straddling the boundary, the next pass skipping
-- them). Bounds are LITERAL constants so TimescaleDB excludes untouched chunks.
create or replace function pgpm.from_hypertable_drain_appends_step(
  p_hypertable regclass, p_control name, p_batch int, p_watermark text
) returns text language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; v_ctl_type text; v_hi text;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';

  -- the batch's upper control bound: the control value p_batch rows past the watermark (or the source's max
  -- past it when fewer remain). The <= insert below includes ALL rows at this value, so no tie is split.
  execute format('select coalesce(
                    (select %I::text from %I.%I where %I > %L::%s order by %I offset %s limit 1),
                    (select max(%I)::text from %I.%I where %I > %L::%s))',
                 p_control, v_nsp, v_rel, p_control, p_watermark, v_ctl_type, p_control, greatest(p_batch - 1, 0),
                 p_control, v_nsp, v_rel, p_control, p_watermark, v_ctl_type) into v_hi;
  if v_hi is null then return p_watermark; end if;   -- nothing past the watermark

  execute format('insert into %I.%I (%s) select %s from %I.%I where %I > %L::%s and %I <= %L::%s order by %I',
                 v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel,
                 p_control, p_watermark, v_ctl_type, p_control, v_hi, v_ctl_type, p_control);
  return v_hi;
end $$;

-- from_hypertable_drain_appends loops the step with a per-batch COMMIT (WAL recycles), mirroring drain_all
-- and from_hypertable_drain_delta (#170). It carries the watermark across batches (the dest's max control,
-- read once up front, then advanced by each step) so it never re-scans the dest for max(). Stops when the
-- residual past the watermark is at/below p_threshold (EXISTS at offset, chunk-excluded). p_max_iter bounds
-- the loop -- raises a loud error UNLESS p_best_effort, in which case it returns so the caller (the cutover)
-- finishes the residual under the lock.
create or replace procedure pgpm.from_hypertable_drain_appends(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_ctl_type text; v_watermark text; v_more boolean; v_iter int := 0;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_appends(%) found no copy to drain -- run from_hypertable_copy first', p_hypertable;
  end if;
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  -- the initial frontier: the copy watermark (max control in the dest). Read once; each step advances it.
  execute format('select max(%I)::text from %I.%I', p_control, v_nsp, v_dest) into v_watermark;
  if v_watermark is null then return; end if;   -- nothing copied (empty dest)
  loop
    -- residual past the watermark <= threshold? EXISTS at offset (chunk-excluded by control > watermark)
    execute format('select exists(select 1 from %I.%I where %I > %L::%s order by %I offset %s limit 1)',
                   v_nsp, v_rel, p_control, v_watermark, v_ctl_type, p_control, p_threshold) into v_more;
    exit when not v_more;
    v_watermark := pgpm.from_hypertable_drain_appends_step(p_hypertable, p_control, p_batch, v_watermark);
    commit;
    v_iter := v_iter + 1;
    if v_iter > p_max_iter then
      if p_best_effort then return; end if;
      raise exception 'pg_partition_magician: from_hypertable_drain_appends(%) did not converge within % iterations -- appends are arriving faster than the drain copies them. Raise p_batch, raise p_threshold to accept a larger final cutover batch, or pause writes before cutting over.',
        p_hypertable, p_max_iter;
    end if;
  end loop;
end $$;

-- Phase 2: the cutover (the one non-online window). ACCESS EXCLUSIVE on the source; an append-only
-- catch-up of rows that arrived after the copy watermark (control >= max copied with a key anti-join on
-- a keyed table, control > max copied on a keyless one); a conservation check that refuses the swap
-- unless the source's count(*) matches the destination's (#460); drop the hypertable
-- (Timescale's event trigger clears its chunks and catalog); rename the copy into place; rebuild the key,
-- secondary indexes, and identity columns (CREATE TABLE LIKE carries none of those) with their original
-- names; then hand off to transmute. The swap + rebuild is one transaction (commits whole or rolls back
-- whole). When the caller leaves p_retain null, the source's drop_chunks policy interval is carried into
-- pgpm's retain. Requires from_hypertable_copy to have run (the destination must exist).
drop procedure if exists pgpm.from_hypertable_cutover(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean);
create or replace procedure pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_predrain boolean default true
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols_q text; v_retain interval;
  v_watermark timestamptz; v_orig regclass; k record;
  v_delta name; v_trgfn name; v_track boolean; v_keycols_q text; v_dkey_q text; v_skey_q text; v_subsel_q text;
  v_ctl_type text; v_min_ctl text; v_max_ctl text;
  v_ident_cols name[]; v_ident_next bigint[]; v_srcseq text; v_srcnext bigint; v_col name;
  v_pseq_q text; v_curnext bigint; v_i int;
  v_tmp text; v_key_names text[]; v_key_types text[]; v_key_tmps text[]; v_idx_orig text[]; v_idx_tmps text[];
  v_in_refs text[]; v_in_names text[]; v_in_defs text[];   -- incoming FKs captured across the swap (#264)
  v_dest_oid regclass;   -- which relation the destination check found, re-verified under lock (#422)
  v_akey oid;            -- the key the append-only catch-up anti-joins by; null on a keyless table (#460)
  v_src_n bigint; v_dest_n bigint; v_n bigint;   -- conservation: source count under lock vs dest baseline + catch-up (#460)
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  -- The dimension facts the copy depended on are re-checked HERE, in the irreversible phase (issue #458).
  -- This procedure used to require only that a destination exist, and a destination left by a copy that
  -- ran under an older version, or made by hand, reaches the DROP below without preflight ever having run.
  -- Only the two dimension checks, not the whole preflight: its disk and time NOTICEs describe a copy that
  -- has already happened, and its foreign-key eligibility was settled before that copy did any work.
  perform pgpm._from_hypertable_check_dimension(p_hypertable, p_control);
  -- Keep the OID this check resolved, not just the fact that something answered (#422). The swap
  -- below renames this relation INTO the source's name, so it is the half of the swap that ends with
  -- a relation BECOMING the production table -- and between here and there the destination is
  -- unlocked (nothing takes a lock on it until the first index pre-build, and the pre-drain's
  -- per-batch commits release even that). Verified under lock at the swap.
  v_dest_oid := to_regclass(format('%I.%I', v_nsp, v_dest));
  if v_dest_oid is null then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found no copy to cut over -- run from_hypertable_copy first',
      p_hypertable;
  end if;
  -- auto-detect change tracking: the copy phase leaves a <rel>_pgpm_delta table iff p_track_changes was set,
  -- so the two phases cannot disagree about the catch-up mode (no matching flag to pass through).
  v_delta := v_rel || '_pgpm_delta';
  v_trgfn := v_rel || '_pgpm_delta_fn';
  v_track := to_regclass(format('%I.%I', v_nsp, v_delta)) is not null;

  -- retention translation: default from the source's drop_chunks policy when the caller did not set one
  v_retain := p_retain;
  if v_retain is null then
    select (config->>'drop_after')::interval into v_retain from timescaledb_information.jobs
     where proc_name = 'policy_retention' and hypertable_schema = v_nsp and hypertable_name = v_rel limit 1;
  end if;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols_q
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into

  -- Pre-drain (#170): when change-tracking is on, reconcile the delta ONLINE in micro-batches before taking
  -- the lock, so the locked final reconcile below applies only a tiny residual instead of the whole
  -- online-copy backlog. Best-effort: if the workload outruns the drain it returns and the under-lock
  -- reconcile finishes whatever is left -- correctness never depends on the pre-drain. p_drain_batch sizes
  -- both the micro-batch and the residual threshold (stop online once the residual is within one batch).
  -- (Commits per batch; the swap transaction below starts fresh after it.)
  if p_predrain and v_track then
    call pgpm.from_hypertable_drain_delta(p_hypertable, p_control, p_drain_batch, p_drain_batch,
                                          1000000, p_best_effort => true);
  elsif p_predrain and not v_track then
    -- append-only path: pre-drain the post-watermark tail online too (#174), so the under-lock catch-up
    -- below applies only the final tail instead of the whole copy's worth of appends.
    call pgpm.from_hypertable_drain_appends(p_hypertable, p_control, p_drain_batch, p_drain_batch,
                                            1000000, p_best_effort => true);
  end if;
  -- Read the destination BEFORE the lock. It is private and stable from here to the lock (only CREATE INDEX
  -- runs, which does not change rows), so what is read here is what the under-lock work would read -- but
  -- reading it here keeps an O(rows) seqscan of the dest OUT of the locked window (#174). Two things, one
  -- scan: the append-only catch-up watermark (max control; new appends after this read have a higher
  -- control value and are still caught under the lock), and the CONSERVATION BASELINE (#460): count(*) of
  -- the dest as it stands, which the catch-up below adjusts by exactly the rows it adds or removes
  -- (row_count) so the check under the lock can compare the two sides without scanning the dest again.
  if not v_track then
    execute format('select count(*), max(%I) from %I.%I', p_control, v_nsp, v_dest) into v_dest_n, v_watermark;
  else
    execute format('select count(*) from %I.%I', v_nsp, v_dest) into v_dest_n;
  end if;
  -- The key the append-only catch-up anti-joins by (#460): the PRIMARY KEY, else a UNIQUE constraint, and
  -- every one of its columns NOT NULL -- a row-constructor `=` never matches a NULL component, so a
  -- nullable key could re-copy a watermark row it cannot recognise (the control column itself is NOT NULL
  -- on any hypertable). The same key from_hypertable_copy tracks by; the pre-build just below puts its
  -- index on the destination before the lock, so the probe is indexed. Null means keyless, and the
  -- catch-up keeps its strict `>` there (see the lock).
  if not v_track then
    select i.indexrelid into v_akey
      from pg_index i
      join pg_constraint con on con.conindid = i.indexrelid and con.contype in ('p', 'u')
     where i.indrelid = p_hypertable
       and not exists (select 1 from unnest(i.indkey) as kc(attnum)
                         join pg_attribute a on a.attrelid = i.indrelid and a.attnum = kc.attnum
                        where not a.attnotnull)
     order by con.contype = 'p' desc, con.conname
     limit 1;
    if v_akey is not null then
      -- (kc, not k: this procedure declares a record named k for its loops, and plpgsql would substitute it)
      select '(' || string_agg('d.' || quote_ident(a.attname), ', ' order by kc.ord) || ')',
             '(' || string_agg('s.' || quote_ident(a.attname), ', ' order by kc.ord) || ')'
        into v_dkey_q, v_skey_q
        from pg_index i
        cross join lateral unnest(i.indkey) with ordinality as kc(attnum, ord)
        join pg_attribute a on a.attrelid = i.indrelid and a.attnum = kc.attnum
       where i.indexrelid = v_akey;
    end if;
  end if;

  -- Pre-build the destination's indexes BEFORE taking the exclusive lock, while the destination is still a
  -- private table and the source keeps serving traffic. This is the O(rows) work; doing it OUTSIDE the lock
  -- is what keeps the cutover's ACCESS EXCLUSIVE window brief -- otherwise the PK + secondary index rebuilds
  -- on the whole table run under the lock (minutes of downtime at scale). Each index is built with a temp
  -- name (the source still owns the originals); the locked swap below then ADOPTS the unique ones as their
  -- original PK/UNIQUE constraints (ALTER TABLE ... USING INDEX -- metadata-only, and it renames the index to
  -- the constraint name) and RENAMES the remaining secondary indexes to their original names (metadata-only).
  -- Builds happen in the same transaction as the swap, so an aborted cutover rolls them back with everything.
  for k in select conname, contype, conindid from pg_constraint
            where conrelid = p_hypertable and contype in ('p', 'u') loop
    v_tmp := left(k.conname || '_pgpm_new', 63);
    -- #175: skip the build if it already exists -- from_hypertable_copy pre-builds the reused-key index
    -- under this same name when tracking, so the drain can use it and the swap below adopts it. Other
    -- constraints (and the append-only / non-tracking path) are built here as before. Always record the
    -- conname -> temp-name mapping so the swap adopts every key index, copy-built or built here.
    if to_regclass(format('%I.%I', v_nsp, v_tmp)) is null then
      execute regexp_replace(pg_get_indexdef(k.conindid),
        '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+',
        '\1' || quote_ident(v_tmp) || ' ON ' || quote_ident(v_nsp) || '.' || quote_ident(v_dest));
    end if;
    v_key_names := array_append(v_key_names, k.conname::text);
    v_key_types := array_append(v_key_types, k.contype::text);
    v_key_tmps  := array_append(v_key_tmps, v_tmp);
  end loop;
  for k in select ic.relname as origname, i.indexrelid from pg_index i join pg_class ic on ic.oid = i.indexrelid
            where i.indrelid = p_hypertable and not i.indisprimary
              and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid) loop
    v_tmp := left(k.origname || '_pgpm_new', 63);
    execute regexp_replace(pg_get_indexdef(k.indexrelid),
      '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+',
      '\1' || quote_ident(v_tmp) || ' ON ' || quote_ident(v_nsp) || '.' || quote_ident(v_dest));
    v_idx_orig := array_append(v_idx_orig, k.origname::text);
    v_idx_tmps := array_append(v_idx_tmps, v_tmp);
  end loop;

  -- LOCK, THEN VERIFY (issue #422). Everything above resolved p_hypertable to a name pair ONCE, at
  -- the top, and a great deal happens before this line -- most expensively the index pre-builds,
  -- which are deliberately out here so the locked window stays brief, and which are therefore the
  -- longest stretch in which the name can stop meaning what it meant. LOCK TABLE freezes whatever a
  -- name means AT LOCK TIME, so locking by name is only half the pattern; without the other half the
  -- DROP below destroys a relation this procedure never identified.
  --
  -- Lock the OID, not the resolved name: p_hypertable::text renders the CURRENT name of the relation
  -- the caller passed, so the lock lands on the hypertable actually being cut over even if it has
  -- been renamed, and nothing can slip in between the lock and the check. THEN require the name to
  -- still resolve back to it. Once that holds, the name is pinned for the rest of the transaction --
  -- a rename needs ACCESS EXCLUSIVE, which this now holds -- so every later `%I.%I` on the source is
  -- safe by construction.
  --
  -- Aborts rather than adapting. There is no partial progress worth keeping: the swap is one
  -- transaction and rolls back whole, the online copy and any drained batches survive, and re-running
  -- the cutover once the name is sorted out costs only the index pre-builds. Adapting -- taking the
  -- source's new name and carrying on -- would silently migrate a table the operator did not name.
  execute format('lock table %s in access exclusive mode', p_hypertable::text);
  if to_regclass(format('%I.%I', v_nsp, v_rel)) is distinct from p_hypertable then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) resolved % .% at the start, but that name is oid % now -- something renamed or replaced the source while the cutover was preparing; refusing to drop a relation it did not identify. Re-run the cutover once the name is settled.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_rel),
      coalesce(to_regclass(format('%I.%I', v_nsp, v_rel))::oid::text, 'nothing');
  end if;

  -- The destination half of the same swap (#422). It is renamed INTO the source's name below, so an
  -- unverified one does not merely get dropped, it BECOMES the table. Lock it by the oid the
  -- existence check resolved and require the name to still mean that, for the same reason and with
  -- the same abort. What this does NOT cover, deliberately: a destination already substituted before
  -- this procedure was ever called. Nothing in this module records what from_hypertable_copy built,
  -- so there is no earlier identity to compare against -- that needs the module-wide oid recording
  -- #422 sketches, which this change does not do.
  execute format('lock table %s in access exclusive mode', v_dest_oid::text);
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is distinct from v_dest_oid then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found destination % .% as oid % at the start, but that name is oid % now -- something replaced the copy while the cutover was preparing; refusing to rename an unverified relation into %.',
      p_hypertable, quote_ident(v_nsp), quote_ident(v_dest), v_dest_oid::oid,
      coalesce(to_regclass(format('%I.%I', v_nsp, v_dest))::oid::text, 'nothing'), quote_ident(v_rel);
  end if;
  if v_track then
    -- change-tracking catch-up: reconcile every touched key against the now-frozen source. Delete each
    -- dirty key's copied version from the destination, then re-insert its current source row -- which is
    -- idempotent and order-independent, and covers inserts, updates, and deletes (a deleted key is simply
    -- absent from the source, so it stays gone). Subsumes the append-only catch-up below.
    select '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
           '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')',
           string_agg(quote_ident(attname), ', ' order by attnum)
      into v_dkey_q, v_skey_q, v_keycols_q
      from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
        and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';   -- exclude the ordering column (#170)
    v_subsel_q := format('select distinct %s from %I.%I', v_keycols_q, v_nsp, v_delta);
    -- The delta was just populated by the trigger, so it has no stats; ANALYZE it so the planner sizes
    -- the semi-joins correctly (the dest was already ANALYZEd at the end of the copy). Shared helper (#164).
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
    -- Bound the source read to the delta's touched control-column range, as LITERAL constants, so
    -- TimescaleDB excludes untouched chunks at plan time -- the reconcile then reads only the chunks that
    -- actually changed, not the whole hypertable. (A min()/max() subquery is a runtime value and does NOT
    -- prune; only constants do.) This is what keeps the locked cutover O(delta), not O(rows): in-flight
    -- changes are time-clustered (an OLTP workload mostly touches recent rows), so the range is a handful of
    -- chunks. SAFE in general: every delta key's control value lies within [min,max] by construction, so no
    -- needed source row can be excluded -- the worst case (changes spanning all history) just prunes nothing.
    select format_type(atttypid, atttypmod) into v_ctl_type
      from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
    execute format('select min(%I)::text, max(%I)::text from %I.%I', p_control, p_control, v_nsp, v_delta)
      into v_min_ctl, v_max_ctl;
    execute format('delete from %I.%I d where %s in (%s)', v_nsp, v_dest, v_dkey_q, v_subsel_q);
    get diagnostics v_n = row_count;
    v_dest_n := v_dest_n - v_n;
    if v_min_ctl is not null then
      execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (%s) and %I >= %L::%s and %I <= %L::%s',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_subsel_q,
                     p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type);
    else
      execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (%s)',
                     v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, v_skey_q, v_subsel_q);
    end if;
    get diagnostics v_n = row_count;
    v_dest_n := v_dest_n + v_n;
  else
    -- append-only catch-up: insert the tail past the watermark (read pre-lock above, off the locked window;
    -- the pre-drain, if it ran, already advanced the dest to within one batch of the head, so this is small).
    --
    -- On a KEYED table the bound is inclusive and a key anti-join skips what the destination already holds
    -- (#460): a row that landed EXACTLY at the watermark during the window is taken rather than lost, and
    -- the copied row already sitting there is not duplicated. Still bounded to the tail on purpose -- an
    -- unbounded anti-join would put an O(rows) probe under the lock. A KEYLESS table keeps the strict `>`:
    -- it has no key to anti-join by, and an all-columns anti-join would be wrong there, since a duplicate
    -- row is legitimate in a keyless table and it would refuse to copy one. Whatever either form cannot
    -- see -- a row behind the watermark on any table, a row at it on a keyless one -- the conservation
    -- check below refuses on, rather than dropping the source short.
    v_n := 0;
    if v_watermark is not null then
      if v_akey is not null then
        -- Materialise the tail first and ANALYZE it, as the tracking branch above does for its delta (#164):
        -- the anti-join must probe the destination's key index once per tail row, and the planner only
        -- chooses that when it knows the tail is small. Estimated straight off the source, the tail is sized
        -- from the newest chunk's statistics, and an overestimate there makes a hash anti-join that seqscans
        -- the WHOLE destination look cheap -- O(rows) under the lock, on a plan nobody sees. Measured: even
        -- at 20k rows the direct form planned a Seq Scan of the destination. On commit drop: the swap
        -- transaction commits below, or rolls back on the refusal, and either ends the temp table.
        execute 'drop table if exists pgpm_htail';
        execute format('create temp table pgpm_htail on commit drop as select %s from %I.%I where %I >= %L',
                       v_cols_q, v_nsp, v_rel, p_control, v_watermark);
        analyze pgpm_htail;
        execute format('insert into %I.%I (%s) select %s from pgpm_htail s where not exists (select 1 from %I.%I d where %s = %s)',
                       v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_dest, v_dkey_q, v_skey_q);
      else
        execute format('insert into %I.%I (%s) select %s from %I.%I where %I > %L',
                       v_nsp, v_dest, v_cols_q, v_cols_q, v_nsp, v_rel, p_control, v_watermark);
      end if;
      get diagnostics v_n = row_count;
    end if;
    v_dest_n := v_dest_n + v_n;
  end if;

  -- CONSERVATION (#460): the one place the two sides of the swap are compared, and it happens BEFORE the
  -- identity capture, the incoming-FK drops and the DROP TABLE below, so on a mismatch nothing outside the
  -- private destination has been touched and the raise rolls the catch-up and the index pre-builds back
  -- with it: the source is left whole and still a hypertable. Both numbers are exact. The source is frozen
  -- under the ACCESS EXCLUSIVE just taken, and the destination's is the pre-lock baseline plus exactly what
  -- the catch-up changed, on a table nothing else writes (the private-destination invariant the watermark
  -- read already rests on). Counting the source is O(rows) under the lock, and there is no bounded read
  -- that could replace it: the rows this exists to find are the ones that landed BELOW the watermark,
  -- anywhere in the table, between the copy and this lock. Counting the destination here too would double
  -- that cost for nothing, which is why its count is carried in rather than taken again.
  --
  -- Refusing beats adapting. The missing rows are below the watermark, so re-running the cutover cannot
  -- find them either; only a copy that tracks changes (or one taken with writes paused) can, and the
  -- message says so. Without this check the loss was silent: no error, no log row, a source dropped short.
  execute format('select count(*) from %I.%I', v_nsp, v_rel) into v_src_n;
  if v_src_n <> v_dest_n then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) refusing to swap: the source holds % rows but the destination would hold % after the % catch-up, a difference of %. %',
      p_hypertable, v_src_n, v_dest_n, case when v_track then 'change-tracking' else 'append-only' end,
      abs(v_src_n - v_dest_n),
      case when v_track
        then 'A write reached the source without firing the change-capture trigger (session_replication_role = replica, or the trigger disabled), so the delta never saw it. Nothing was dropped and the source is whole. Make every writer fire triggers, then re-run from_hypertable_copy with p_track_changes => true.'
        else format('Rows arrived during the online window with a control value at or below the copy watermark (out-of-order appends, a backfill, or an update or delete of a copied row), which the append-only catch-up cannot see. Nothing was dropped and the source is whole. Re-run from_hypertable_copy(%L, %L, p_track_changes => true), which needs a primary key or unique constraint; on a keyless table, pause writes to the source for the copy instead.',
                    p_hypertable::text, p_control)
      end;
  end if;
  -- (the key constraints + secondary indexes were captured and pre-built on the destination above, before
  -- the lock; the swap below only adopts/renames them -- metadata-only.)
  -- identity columns: CREATE TABLE (LIKE ...) does NOT carry identity, so the destination's column is a
  -- plain (already-populated) column. Capture which columns were identity on the source so we can re-add
  -- the property after the rename. Also capture each source sequence's NEXT value: transmute only reseeds
  -- the new sequence past max(id), but a source sequence can sit AHEAD of max(id) (rolled-back inserts,
  -- sequence caching, deleted high rows), so we advance the migrated sequence to the source's position
  -- after the handoff -- otherwise those skipped-over ids would be handed back out. (transmute normalises
  -- identity to GENERATED BY DEFAULT, so we re-add it that way to match the end state regardless of kind.)
  for k in select attname from pg_attribute
            where attrelid = p_hypertable and attidentity in ('a', 'd') and not attisdropped order by attnum loop
    v_ident_cols := array_append(v_ident_cols, k.attname);
    v_srcseq := pg_get_serial_sequence(p_hypertable::text, k.attname::text);
    v_srcnext := null;
    if v_srcseq is not null then
      execute format('select case when is_called then last_value + 1 else last_value end from %s', v_srcseq)
        into v_srcnext;
    end if;
    v_ident_next := array_append(v_ident_next, v_srcnext);
  end loop;
  -- OUTGOING foreign keys need no work here any more (#263). from_hypertable_copy already added them to
  -- the private destination and VALIDATED them there, off the lock; the destination then becomes the
  -- monolith child, and transmute re-adds every validated outgoing key at the new parent as part of its own
  -- cutover. This used to do that re-add itself (#264, when transmute did not), and doing BOTH now fails
  -- with `constraint "..." already exists`: the copy-phase validation is what makes transmute's adoption
  -- metadata-only, so that half stays and this half goes.

  -- INCOMING foreign keys (issue #264). An FK pointing AT the hypertable puts a constraint on each chunk,
  -- so `drop table <source>` below was refused outright -- and only here, after the entire online copy had
  -- run, leaving the populated destination orphaned behind the rollback:
  --
  --   ERROR: cannot drop table _timescaledb_internal._hyper_2_2_chunk because other objects depend on it
  --   DETAIL: constraint annotations_r_id_r_ts_fkey on table annotations depends on _hyper_2_2_chunk
  --
  -- Capture each definition and drop the constraint, which is what unblocks the drop. The recorded
  -- definition names the referenced table BY NAME, and the new parent takes the source's name, so it
  -- replays verbatim afterwards -- the same property transmute's own preserve path relies on. Captured
  -- through the core's _fk_definition (#498), which pins the search_path so the name is schema-qualified:
  -- the row goes to pgpm.dropped_fk, and a re-add that does not succeed below is retried by maintain in
  -- pg_cron's session, whose search_path is not this one's.
  --
  -- Deliberately NOT re-added here: doing so would leave an incoming FK in place when the plain table is
  -- handed to transmute, which refuses one by default, and asking for 'preserve' would just have transmute
  -- drop it again. The re-add happens after the handoff, through the core's dropped_fk machinery.
  -- The eligibility of these keys was settled in the preflight, before any copy work.
  for k in
    select c.conrelid::regclass as referencing, c.conname, pgpm._fk_definition(c.oid) as def
      from pg_constraint c
     where c.confrelid = p_hypertable and c.contype = 'f' and c.conrelid <> p_hypertable
       and c.conparentid = 0
     order by c.conname
  loop
    v_in_refs := array_append(v_in_refs, k.referencing::text);
    v_in_names := array_append(v_in_names, k.conname::text);
    v_in_defs := array_append(v_in_defs, k.def);
    execute format('alter table %s drop constraint %I', k.referencing::text, k.conname);
  end loop;

  execute format('drop table %I.%I', v_nsp, v_rel);   -- also drops the change-capture trigger, if any
  if v_track then
    -- the trigger went with the source; drop the now-orphaned delta table and trigger function. This is
    -- inside the swap transaction, so an aborted cutover leaves the apparatus intact with the source.
    execute format('drop table %I.%I', v_nsp, v_delta);
    execute format('drop function if exists %I.%I()', v_nsp, v_trgfn);
  end if;
  execute format('alter table %I.%I rename to %I', v_nsp, v_dest, v_rel);
  -- adopt the pre-built unique indexes as the original PK/UNIQUE constraints (metadata-only; USING INDEX
  -- also renames the adopted index to the constraint name)
  for v_i in 1 .. coalesce(array_length(v_key_names, 1), 0) loop
    execute format('alter table %I.%I add constraint %I %s using index %I',
                   v_nsp, v_rel, v_key_names[v_i],
                   case when v_key_types[v_i] = 'p' then 'primary key' else 'unique' end,
                   v_key_tmps[v_i]);
  end loop;
  -- rename the pre-built secondary indexes to their original names (metadata-only)
  for v_i in 1 .. coalesce(array_length(v_idx_orig, 1), 0) loop
    execute format('alter index %I.%I rename to %I', v_nsp, v_idx_tmps[v_i], v_idx_orig[v_i]);
  end loop;
  if v_ident_cols is not null then
    foreach v_col in array v_ident_cols loop
      execute format('alter table %I.%I alter column %I add generated by default as identity', v_nsp, v_rel, v_col);
    end loop;
  end if;
  commit;

  -- handoff: an ordinary plain table under the original name is exactly transmute's input.
  v_orig := format('%I.%I', v_nsp, v_rel)::regclass;
  -- transmute is a PROCEDURE since #275 (it commits between adding the monolith bound, validating it, and
  -- the cutover, so the O(rows) scan is not held under ACCESS EXCLUSIVE). The commit above at :684 means
  -- this runs in a fresh transaction, so its internal commits are legal here.
  -- p_drain_batch sizes THIS module's migration-delta drain, which still exists; transmute's own batch
  -- knob is regrain's now (#288), so the handoff names it explicitly rather than relying on position.
  call pgpm.transmute(v_orig, p_control, p_interval, p_obtain, v_retain,
                      p_regrain_batch => p_drain_batch, p_anchor => p_anchor, p_paused => p_paused);

  -- Re-add the incoming FKs the swap dropped, now against the new partitioned parent (issue #264). Handed
  -- to the CORE's existing state machine rather than re-implementing the dance: recording them in
  -- pgpm.dropped_fk means restore_incoming_fks re-adds each NOT VALID (O(1), and enforcing every new write
  -- immediately) and validate_incoming_fks does the scan in its own transaction, with the orphan reporting,
  -- the validate back-off, and status().fks_suspended / fks_unvalidated all coming for free. Re-resolved by
  -- name because after transmute v_orig's oid is the monolith child, not the parent.
  --
  -- The window from the drop above to this re-add is real and bounded by the swap plus one transmute. It
  -- cannot be closed by re-adding inside the cutover -- transmute would then refuse the incoming key -- so
  -- it is surfaced rather than hidden, which is what pgpm.dropped_fk and status().fks_suspended are for.
  if v_in_names is not null then
    for v_i in 1 .. array_length(v_in_names, 1) loop
      insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
        values (format('%I.%I', v_nsp, v_rel)::regclass, v_in_refs[v_i]::regclass,
                v_in_names[v_i], v_in_defs[v_i]);
      insert into pgpm.log (parent_table, action, method)
        values (format('%I.%I', v_nsp, v_rel)::regclass, 'drop_incoming_fk', v_in_names[v_i]);
    end loop;
    commit;
    perform pgpm.restore_incoming_fks(format('%I.%I', v_nsp, v_rel)::regclass);
    commit;
    perform pgpm.validate_incoming_fks(format('%I.%I', v_nsp, v_rel)::regclass);
    commit;
  end if;

  -- preserve the source sequence's exact position. transmute moved identity to the new parent and seeded
  -- each sequence to max(id)+1; advance it to the source's captured next value when that is higher, so ids
  -- the source had already moved past are not reissued. setval(..., false) makes the value the next handed
  -- out. (Re-resolve the parent by name: after transmute, v_orig's oid is the monolith child, not the parent.)
  if v_ident_cols is not null then
    for v_i in 1 .. array_length(v_ident_cols, 1) loop
      if v_ident_next[v_i] is not null then
        v_pseq_q := pg_get_serial_sequence(format('%I.%I', v_nsp, v_rel), v_ident_cols[v_i]::text);
        if v_pseq_q is not null then
          execute format('select case when is_called then last_value + 1 else last_value end from %s', v_pseq_q)
            into v_curnext;
          if v_ident_next[v_i] > coalesce(v_curnext, 0) then
            execute format('select setval(%L, %s, false)', v_pseq_q, v_ident_next[v_i]);
          end if;
        end if;
      end if;
    end loop;
  end if;
  commit;
end $$;

-- The one-shot driver: copy then cut over, back to back. Use the two phases directly instead when writes
-- must keep arriving during the migration (copy, let the workload run, then cutover catches up the appends).
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, boolean);
-- #288 dropped p_keep_default, so the previous form must go or both overloads survive and every call
-- becomes ambiguous.
drop procedure if exists pgpm.from_hypertable(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, boolean, boolean);
create or replace procedure pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false, p_predrain boolean default true
) language plpgsql as $$
begin
  call pgpm.from_hypertable_copy(p_hypertable, p_control, p_track_changes);
  call pgpm.from_hypertable_cutover(p_hypertable, p_control, p_interval, p_obtain, p_retain,
                                    p_drain_batch, p_anchor, p_paused, p_predrain);
end $$;
