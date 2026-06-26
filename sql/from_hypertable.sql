-- =============================================================================
-- pg_partition_magician :: from_hypertable  --  migrate a TimescaleDB hypertable
-- to a pgpm-managed native RANGE partition set.
--
-- OPTIONAL add-on, loaded ON TOP of the core (sql/pg_partition_magician.sql) and
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
-- handoff, since CREATE TABLE LIKE does not carry identity). Refused up front:
-- continuous aggregates and space partitioning (>1 dimension); transmute also
-- refuses a nullable control column, a key that excludes it, or a bare unique
-- index. A trigger-based delta for update/delete workloads is a follow-up.
-- Known gaps (shared with core transmute/drain/refine, tracked separately): a GENERATED column cannot be
-- migrated (the copy's column list includes it and the INSERT is rejected), and a CHECK constraint is
-- carried to the monolith but not propagated to the partitioned parent (so new partitions do not enforce
-- it). Tables with either are out of scope for this version.
-- =============================================================================

-- from_hypertable_preflight: the refusal checks, factored out so they are callable on their own (a
-- dry-run gate) and unit-testable inside a transaction. Raises a pgpm-prefixed error on any blocker;
-- returns normally when the hypertable is migratable by this version.
create or replace function pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name)
returns void language plpgsql as $$
declare v_nsp name; v_rel name; v_cagg text; v_dims int; v_ctl_attnum int;
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
end $$;

-- from_hypertable runs in two phases, exposed as separate procedures so writes can keep arriving between
-- them: from_hypertable_copy does the online bulk copy to a watermark, then from_hypertable_cutover catches
-- up the rows that arrived after it, swaps the copy into place, and hands off to transmute. from_hypertable
-- runs both back to back for the one-shot case. All are procedures because the copy commits per chunk
-- (bounded WAL/txn on a large table) and the cutover commits the swap.

-- Phase 1: build the plain destination and bulk-copy the existing chunks into it, online. The source keeps
-- serving traffic (new appends are caught up by the cutover). Leaves <rel>_pgpm_dest populated; the copy
-- watermark is implicitly max(control) in the destination.
create or replace procedure pgpm.from_hypertable_copy(p_hypertable regclass, p_control name)
language plpgsql as $$
declare v_nsp name; v_rel name; v_dest name; v_cols text; r record;
begin
  perform pgpm.from_hypertable_preflight(p_hypertable, p_control);
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped;

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
end $$;

-- Phase 2: the cutover (the one non-online window). Brief ACCESS EXCLUSIVE on the source; an append-only
-- catch-up of rows that arrived after the copy watermark (control > max copied); drop the hypertable
-- (Timescale's event trigger clears its chunks and catalog); rename the copy into place; rebuild the key,
-- secondary indexes, and identity columns (CREATE TABLE LIKE carries none of those) with their original
-- names; then hand off to transmute. The swap + rebuild is one transaction (commits whole or rolls back
-- whole). When the caller leaves p_retain null, the source's drop_chunks policy interval is carried into
-- pgpm's retain. Requires from_hypertable_copy to have run (the destination must exist).
create or replace procedure pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols text; v_retain interval;
  v_watermark timestamptz; v_orig regclass; k record;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';
  if to_regclass(format('%I.%I', v_nsp, v_dest)) is null then
    raise exception 'pg_partition_magician: from_hypertable_cutover(%) found no copy to cut over -- run from_hypertable_copy first',
      p_hypertable;
  end if;

  -- retention translation: default from the source's drop_chunks policy when the caller did not set one
  v_retain := p_retain;
  if v_retain is null then
    select (config->>'drop_after')::interval into v_retain from timescaledb_information.jobs
     where proc_name = 'policy_retention' and hypertable_schema = v_nsp and hypertable_name = v_rel limit 1;
  end if;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped;

  execute format('lock table %I.%I in access exclusive mode', v_nsp, v_rel);
  execute format('select max(%I) from %I.%I', p_control, v_nsp, v_dest) into v_watermark;
  if v_watermark is not null then
    execute format('insert into %I.%I (%s) select %s from %I.%I where %I > %L',
                   v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel, p_control, v_watermark);
  end if;
  create temporary table _fh_keys on commit drop as
    select conname::text as nm, pg_get_constraintdef(oid) as def
      from pg_constraint where conrelid = p_hypertable and contype in ('p', 'u');
  create temporary table _fh_idx on commit drop as
    select pg_get_indexdef(i.indexrelid) as def
      from pg_index i
     where i.indrelid = p_hypertable and not i.indisprimary
       and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid);
  -- identity columns: CREATE TABLE (LIKE ...) does NOT carry identity, so the destination's column is a
  -- plain (already-populated) column. Capture which columns were identity on the source so we can re-add
  -- the property after the rename; transmute then reseeds the sequence past the max migrated value, so
  -- inserts that omit the column keep auto-generating without collision. (transmute normalises identity to
  -- GENERATED BY DEFAULT, so we re-add it that way to match the end state regardless of the source kind.)
  create temporary table _fh_ident on commit drop as
    select attname::text as nm from pg_attribute
     where attrelid = p_hypertable and attidentity in ('a', 'd') and not attisdropped;
  execute format('drop table %I.%I', v_nsp, v_rel);
  execute format('alter table %I.%I rename to %I', v_nsp, v_dest, v_rel);
  for k in select nm, def from _fh_keys loop
    execute format('alter table %I.%I add constraint %I %s', v_nsp, v_rel, k.nm, k.def);
  end loop;
  for k in select def from _fh_idx loop
    execute k.def;   -- names the original index and (post-rename) the original table name
  end loop;
  for k in select nm from _fh_ident loop
    execute format('alter table %I.%I alter column %I add generated by default as identity', v_nsp, v_rel, k.nm);
  end loop;
  commit;

  -- handoff: an ordinary plain table under the original name is exactly transmute's input.
  v_orig := format('%I.%I', v_nsp, v_rel)::regclass;
  perform pgpm.transmute(v_orig, p_control, p_interval, p_obtain, v_retain,
                         p_keep_default, p_drain_batch, p_anchor, p_paused);
  commit;
end $$;

-- The one-shot driver: copy then cut over, back to back. Use the two phases directly instead when writes
-- must keep arriving during the migration (copy, let the workload run, then cutover catches up the appends).
create or replace procedure pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true
) language plpgsql as $$
begin
  call pgpm.from_hypertable_copy(p_hypertable, p_control);
  call pgpm.from_hypertable_cutover(p_hypertable, p_control, p_interval, p_obtain, p_retain,
                                    p_keep_default, p_drain_batch, p_anchor, p_paused);
end $$;
