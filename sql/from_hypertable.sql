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

-- from_hypertable: the migration driver. Online chunk-by-chunk COPY into a plain destination, then a
-- brief-lock cutover (append-only catch-up, drop the hypertable, rename the copy into its place), then
-- transmute. A procedure because the copy commits per chunk (bounded WAL/txn on a large table). When the
-- caller leaves p_retain null, the source's drop_chunks policy interval is carried into pgpm's retain.
create or replace procedure pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_dest name; v_cols text; v_retain interval;
  v_watermark timestamptz; v_orig regclass; r record; k record;
begin
  -- 1. refuse up front (leaves the hypertable untouched)
  perform pgpm.from_hypertable_preflight(p_hypertable, p_control);

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_hypertable;
  v_dest := v_rel || '_pgpm_dest';

  -- retention translation: default from the source's drop_chunks policy when the caller did not set one
  v_retain := p_retain;
  if v_retain is null then
    select (config->>'drop_after')::interval into v_retain from timescaledb_information.jobs
     where proc_name = 'policy_retention' and hypertable_schema = v_nsp and hypertable_name = v_rel limit 1;
  end if;

  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_hypertable and attnum > 0 and not attisdropped;

  -- 2. destination skeleton: structure but no indexes/key, so the bulk load maintains no per-row index.
  execute format('drop table if exists %I.%I', v_nsp, v_dest);
  execute format('create table %I.%I (like %I.%I including defaults including constraints including generated including comments)',
                 v_nsp, v_dest, v_nsp, v_rel);
  commit;

  -- 3. online chunk-bounded copy: one chunk-range per transaction (the time predicate drives chunk
  -- exclusion to a single-chunk read; ORDER BY the control column clusters the destination for cheap
  -- transmute/refine later). The source keeps serving traffic throughout.
  for r in select range_start, range_end from timescaledb_information.chunks
            where hypertable_schema = v_nsp and hypertable_name = v_rel order by range_start loop
    execute format('insert into %I.%I (%s) select %s from %I.%I where %I >= %L and %I < %L order by %I',
                   v_nsp, v_dest, v_cols, v_cols, v_nsp, v_rel,
                   p_control, r.range_start, p_control, r.range_end, p_control);
    commit;
  end loop;

  -- 4. cutover (the one non-online window): brief ACCESS EXCLUSIVE on the source, append-only catch-up of
  -- rows that arrived after the copy watermark, drop the hypertable (Timescale's event trigger clears its
  -- chunks and catalog), rename the copy into place, and rebuild the key + secondary indexes with their
  -- original names (free now that the source is gone). One transaction: it commits whole or rolls back whole.
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

  -- 5. handoff: an ordinary plain table under the original name is exactly transmute's input.
  v_orig := format('%I.%I', v_nsp, v_rel)::regclass;
  perform pgpm.transmute(v_orig, p_control, p_interval, p_obtain, v_retain,
                         p_keep_default, p_drain_batch, p_anchor, p_paused);
  commit;
end $$;
