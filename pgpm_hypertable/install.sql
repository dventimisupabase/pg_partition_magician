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
-- brief lock. Scope: a single time/RANGE dimension; append-only catch-up at
-- cutover. The control column's key is whatever transmute reuses -- a PRIMARY KEY
-- or UNIQUE constraint that includes it, or keyless if it has neither (the common
-- hypertable shape). Identity columns are preserved (re-established before the
-- handoff, since CREATE TABLE LIKE does not carry identity), generated columns are
-- preserved (the copy omits them from its column list and they recompute on
-- insert), and CHECK constraints, defaults, and NOT NULL are carried onto the
-- partitioned parent by transmute. Refused up front: continuous aggregates and
-- space partitioning (>1 dimension); transmute also refuses a nullable control
-- column, a key that excludes it, or a bare unique index.
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
-- and an optional later refine are additional. Callable on its own for sizing.
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

-- from_hypertable_preflight: the refusal checks, factored out so they are callable on their own (a
-- dry-run gate) and unit-testable inside a transaction. Raises a pgpm-prefixed error on any blocker;
-- returns normally when the hypertable is migratable by this version (with a NOTICE estimating the disk).
create or replace function pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare
  v_nsp name; v_rel name; v_cagg text; v_dims int; v_ctl_attnum int; v_bytes bigint;
  v_cache bigint; v_mibps numeric; v_regime text; v_eta interval;
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
  raise notice 'pg_partition_magician: estimated online copy time ~ % (% at ~% MiB/s, %). This covers the copy only -- the cutover then rebuilds the primary key and secondary indexes (extra, scales with row count) and a later refine (if used) is a similar second pass. Rough (measured on a 2XL gp3): more RAM/IOPS/throughput is faster. Override the rate with pgpm.from_hypertable_time_estimate(table, mibps).',
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
  v_nsp name; v_rel name; v_dest name; v_cols text; r record;
  v_delta name; v_trgfn name; v_trg name; v_keyidx oid; v_keycols text; v_newvals text; v_oldvals text;
begin
  perform pgpm.from_hypertable_preflight(p_hypertable, p_control);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into

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
      into v_keycols, v_newvals, v_oldvals
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
                   v_nsp, v_delta, v_keycols, v_nsp, v_rel);
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
      v_nsp, v_delta, v_keycols, v_oldvals,
      v_nsp, v_delta, v_keycols, v_oldvals, v_newvals,
      v_nsp, v_delta, v_keycols, v_newvals);
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
  -- to a single-chunk read; ORDER BY the control column clusters the destination for cheap transmute/refine
  -- later). The source keeps serving traffic throughout.
  for r in select range_start, range_end from timescaledb_information.chunks
            where hypertable_schema = v_nsp and hypertable_name = v_rel order by range_start loop
    execute format('insert into %I.%I (%s) select %s from %I.%I where %I >= %L and %I < %L order by %I',
                   v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel,
                   p_control, r.range_start, p_control, r.range_end, p_control);
    commit;
  end loop;
  -- The destination was just CREATE TABLE LIKE'd and bulk-loaded, so it has no planner stats (reltuples=0).
  -- ANALYZE it now -- while it is still private and unlocked -- so the cutover's delta reconcile plans
  -- against the real row count. Without this the planner thinks the dest is empty and seqscans the whole
  -- table for the reconcile, making the (locked) cutover O(rows) instead of O(delta). pgpm._analyze is the
  -- core's shared mint-then-populate ANALYZE helper (#164).
  perform pgpm._analyze(format('%I.%I', v_nsp, v_dest)::regclass);
  commit;
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
  v_nsp name; v_rel name; v_dest name; v_delta name; v_drainkey name;
  v_keycols text; v_dkey text; v_skey text; v_cols text;
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
    into v_keycols, v_dkey, v_skey
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- the source/dest column list for the reinsert (generated columns omitted: they recompute on insert)
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped and attgenerated = '';

  -- the dest has no indexes after the bulk copy; without a key index every batch's dest delete seqscans the
  -- whole dest. Build it once (if-not-exists; the driver normally builds it before the loop).
  v_drainkey := left(v_rel || '_pgpm_drainkey', 63);
  if to_regclass(format('%I.%I', v_nsp, v_drainkey)) is null then
    execute format('create index %I on %I.%I (%s)', v_drainkey, v_nsp, v_dest, v_keycols);
  end if;

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
                 v_nsp, v_delta, v_watermark, v_keycols, v_keycols);
  get diagnostics v_keys = row_count;

  -- bound the source read to the batch's touched control range, as literal constants, for chunk exclusion
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  execute format('select min(%I)::text, max(%I)::text from pgpm_dbatch', p_control, p_control)
    into v_min_ctl, v_max_ctl;

  -- reconcile: drop the batch's keys from the dest, then reinsert their current source rows
  execute format('delete from %I.%I d where %s in (select %s from pgpm_dbatch)', v_nsp, v_dest, v_dkey, v_keycols);
  if v_min_ctl is not null then
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch) and %I >= %L::%s and %I <= %L::%s',
                   v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, v_skey, v_keycols,
                   p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type);
  else
    execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from pgpm_dbatch)',
                   v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, v_skey, v_keycols);
  end if;
  return v_keys;
end $$;

-- from_hypertable_drain_delta loops the step with a per-batch COMMIT (so WAL recycles -- the same reason
-- from_hypertable_copy commits per chunk), mirroring drain_all's _step + _all shape. It chases the backlog
-- down until the residual is at/below p_threshold (0 = drain to empty), tested cheaply with an EXISTS at
-- offset (like drain_step's EXISTS-not-count). Under sustained write load the residual may never reach the
-- threshold; p_max_iter bounds the loop -- it raises a loud, actionable error UNLESS p_best_effort, in which
-- case it returns so the caller (the cutover) can take the lock and finish the now-smaller residual under it.
-- The first batch with work builds the dest's drain key index (in its own transaction, skipped when there is
-- nothing to drain) and leaves it for the cutover to drop, so repeated operator calls reuse it.
create or replace procedure pgpm.from_hypertable_drain_delta(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_delta name; v_drainkey name; v_keycols text;
  v_iter int := 0; v_more boolean;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  v_delta := v_rel || '_pgpm_delta';
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    raise exception 'pg_partition_magician: from_hypertable_drain_delta(%) found no delta -- change tracking was not enabled by from_hypertable_copy', p_hypertable;
  end if;

  select string_agg(quote_ident(attname), ', ' order by attnum) into v_keycols
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  v_drainkey := left(v_rel || '_pgpm_drainkey', 63);

  loop
    -- residual <= threshold? EXISTS at offset stops at the first row past the threshold (count > threshold)
    execute format('select exists(select 1 from %I.%I order by pgpm_seq offset %s limit 1)',
                   v_nsp, v_delta, p_threshold) into v_more;
    exit when not v_more;
    -- there is work to drain: build the dest's drain key index once, in its own transaction (without it the
    -- per-batch dest delete seqscans the whole dest), keeping the O(rows) build out of the first batch and
    -- skipping it entirely when there is nothing to drain.
    if to_regclass(format('%I.%I', v_nsp, v_drainkey)) is null then
      execute format('create index %I on %I.%I (%s)', v_drainkey, v_nsp, v_dest, v_keycols);
      commit;
    end if;
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
-- contract (no updates/deletes to copied rows), exactly as the under-lock catch-up already does -- use
-- p_track_changes for update/delete workloads.

-- from_hypertable_drain_appends_step copies ONE batch of appends past p_watermark and returns the new
-- watermark (the batch's upper control bound, as text); no commit (the driver commits per batch). The batch
-- is bounded to ~p_batch rows by the control value p_batch rows past the watermark, INCLUSIVE of ties at that
-- bound (a row-count LIMIT with a strict > would drop ties straddling the boundary, the next pass skipping
-- them). Bounds are LITERAL constants so TimescaleDB excludes untouched chunks.
create or replace function pgpm.from_hypertable_drain_appends_step(
  p_hypertable regclass, p_control name, p_batch int, p_watermark text
) returns text language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols text; v_ctl_type text; v_hi text;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select format_type(atttypid, atttypmod) into v_ctl_type
    from pg_attribute where attrelid = p_hypertable and attname = p_control and not attisdropped;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
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
                 v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel,
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

-- Phase 2: the cutover (the one non-online window). Brief ACCESS EXCLUSIVE on the source; an append-only
-- catch-up of rows that arrived after the copy watermark (control > max copied); drop the hypertable
-- (Timescale's event trigger clears its chunks and catalog); rename the copy into place; rebuild the key,
-- secondary indexes, and identity columns (CREATE TABLE LIKE carries none of those) with their original
-- names; then hand off to transmute. The swap + rebuild is one transaction (commits whole or rolls back
-- whole). When the caller leaves p_retain null, the source's drop_chunks policy interval is carried into
-- pgpm's retain. Requires from_hypertable_copy to have run (the destination must exist).
drop procedure if exists pgpm.from_hypertable_cutover(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean);
create or replace procedure pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_predrain boolean default true
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols text; v_retain interval;
  v_watermark timestamptz; v_orig regclass; k record;
  v_delta name; v_trgfn name; v_track boolean; v_keycols text; v_dkey text; v_skey text; v_subsel text;
  v_ctl_type text; v_min_ctl text; v_max_ctl text;
  v_ident_cols name[]; v_ident_next bigint[]; v_srcseq text; v_srcnext bigint; v_col name;
  v_pseq text; v_curnext bigint; v_i int;
  v_tmp text; v_key_names text[]; v_key_types text[]; v_key_tmps text[]; v_idx_orig text[]; v_idx_tmps text[];
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is null then
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
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
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
  -- the pre-drain (or an operator's from_hypertable_drain_delta) builds a throwaway key index on the dest;
  -- drop it so it never survives the rename onto the final table (the real key index is built + adopted below).
  execute format('drop index if exists %I.%I', v_nsp, left(v_rel || '_pgpm_drainkey', 63));
  -- append-only: read the catch-up watermark (max control in the dest) BEFORE the lock. The dest is private
  -- and stable from here to the lock (only CREATE INDEX runs, which does not change rows), so this is the
  -- same value the under-lock catch-up would read -- but doing it here keeps an O(rows) max() seqscan on a
  -- keyless dest OUT of the locked window (#174). New appends after this read have a higher control value
  -- and are still caught by the under-lock `control > watermark`.
  if not v_track then
    execute format('select max(%I) from %I.%I', p_control, v_nsp, v_dest) into v_watermark;
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
    execute regexp_replace(pg_get_indexdef(k.conindid),
      '^(CREATE (UNIQUE )?INDEX )[^ ]+ ON [^ ]+',
      '\1' || quote_ident(v_tmp) || ' ON ' || quote_ident(v_nsp) || '.' || quote_ident(v_dest));
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

  execute format('lock table %I.%I in access exclusive mode', v_nsp, v_rel);
  if v_track then
    -- change-tracking catch-up: reconcile every touched key against the now-frozen source. Delete each
    -- dirty key's copied version from the destination, then re-insert its current source row -- which is
    -- idempotent and order-independent, and covers inserts, updates, and deletes (a deleted key is simply
    -- absent from the source, so it stays gone). Subsumes the append-only catch-up below.
    select '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
           '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')',
           string_agg(quote_ident(attname), ', ' order by attnum)
      into v_dkey, v_skey, v_keycols
      from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
        and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';   -- exclude the ordering column (#170)
    v_subsel := format('select distinct %s from %I.%I', v_keycols, v_nsp, v_delta);
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
    execute format('delete from %I.%I d where %s in (%s)', v_nsp, v_dest, v_dkey, v_subsel);
    if v_min_ctl is not null then
      execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (%s) and %I >= %L::%s and %I <= %L::%s',
                     v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, v_skey, v_subsel,
                     p_control, v_min_ctl, v_ctl_type, p_control, v_max_ctl, v_ctl_type);
    else
      execute format('insert into %I.%I (%s) select %s from %I.%I s where %s in (%s)',
                     v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, v_skey, v_subsel);
    end if;
  else
    -- append-only catch-up: insert the tail past the watermark (read pre-lock above, off the locked window;
    -- the pre-drain, if it ran, already advanced the dest to within one batch of the head, so this is small).
    if v_watermark is not null then
      execute format('insert into %I.%I (%s) select %s from %I.%I where %I > %L',
                     v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, p_control, v_watermark);
    end if;
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
  perform pgpm.transmute(v_orig, p_control, p_interval, p_obtain, v_retain,
                         p_keep_default, p_drain_batch, p_anchor, p_paused);

  -- preserve the source sequence's exact position. transmute moved identity to the new parent and seeded
  -- each sequence to max(id)+1; advance it to the source's captured next value when that is higher, so ids
  -- the source had already moved past are not reissued. setval(..., false) makes the value the next handed
  -- out. (Re-resolve the parent by name: after transmute, v_orig's oid is the monolith child, not the parent.)
  if v_ident_cols is not null then
    for v_i in 1 .. array_length(v_ident_cols, 1) loop
      if v_ident_next[v_i] is not null then
        v_pseq := pg_get_serial_sequence(format('%I.%I', v_nsp, v_rel), v_ident_cols[v_i]::text);
        if v_pseq is not null then
          execute format('select case when is_called then last_value + 1 else last_value end from %s', v_pseq)
            into v_curnext;
          if v_ident_next[v_i] > coalesce(v_curnext, 0) then
            execute format('select setval(%L, %s, false)', v_pseq, v_ident_next[v_i]);
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
create or replace procedure pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false, p_predrain boolean default true
) language plpgsql as $$
begin
  call pgpm.from_hypertable_copy(p_hypertable, p_control, p_track_changes);
  call pgpm.from_hypertable_cutover(p_hypertable, p_control, p_interval, p_obtain, p_retain,
                                    p_keep_default, p_drain_batch, p_anchor, p_paused, p_predrain);
end $$;
