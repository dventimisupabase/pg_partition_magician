-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL range-partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling). No compiled
--     extension. Install with: psql -f this_file.sql.  Schema: pgpm.
--   * Manages the full lifecycle of native RANGE-partitioned tables: adopt an
--     existing (possibly huge, live) table online, premake ahead of the write
--     frontier, drain the DEFAULT's closed tail, retention, all via maintenance.
--
-- Control-type contract -- a column works as the partition key if it is:
--   (a) RANGE-partitionable (btree-ordered),
--   (b) monotonic with insertion within a bounded lag,
--   (c) has EXACT, reproducible grid arithmetic (gapless, stable boundaries),
--   (d) free of unordered/extreme values that poison the frontier (NaN/Inf/wrap).
--
-- Supported control_kind:
--   'time'    -- timestamptz/timestamp/date, interval step (calendar-aligned)
--   'id'      -- int/bigint/NUMERIC, integer step (covers Snowflake-style ids)
--   'uuidv7'  -- uuid whose leading 48 bits are a ms timestamp (also ULID-as-uuid);
--                time grid, boundaries encoded as uuids
-- float/double are explicitly rejected (imprecise boundaries; NaN/Inf).
--
-- The engine is kind-agnostic: all type-specific logic lives in a small adapter
-- (_grid_floor/_grid_next/_encode/_decode/_frontier_native/_part_name). Bounds are
-- carried as text so one code path serves every kind.
-- =============================================================================

create schema if not exists pgpm;

create table if not exists pgpm.config (
  parent_table     regclass    primary key,
  control_column   name        not null,
  control_kind     text        not null default 'time'
                   check (control_kind in ('time', 'id', 'uuidv7')),
  partition_step   text        not null,    -- '1 month' (time/uuidv7) | '10000000' (id)
  partition_anchor text        not null,    -- '2000-01-01...' (time/uuidv7) | '0' (id)
  premake          int         not null default 4,
  retention        text,                    -- interval (time/uuidv7) | bigint count (id); null = keep
  keep_default     boolean     not null default true,
  drain_batch      int         not null default 5000,
  default_table    name        not null,
  paused           boolean     not null default true,
  created_at       timestamptz not null default now(),
  -- when maintenance may next attempt premake for this parent. Under sustained write contention
  -- premake keeps losing the ACCESS EXCLUSIVE race, so on a deferral maintenance backs it off
  -- instead of retrying (and risking a wasted default scan) every tick. null = attempt now.
  premake_retry_after timestamptz,
  -- optional block budget for the drain: cap each microbatch at ~this many heap+TOAST blocks
  -- (translated to a row limit via the default's average bytes/row), so wide rows can't make a
  -- single batch huge. null = cap by drain_batch rows only (default). See DESIGN.md section 8.
  drain_max_blocks int
);
-- upgrade path for installs that predate these columns
alter table pgpm.config add column if not exists premake_retry_after timestamptz;
alter table pgpm.config add column if not exists drain_max_blocks int;

-- Registry of managed partitions (excludes the DEFAULT). lo/hi are NATIVE-grid
-- values as text (timestamptz for time/uuidv7, numeric for id).
create table if not exists pgpm.part (
  parent_table regclass    not null,
  child_name   name        not null,
  lo           text        not null,
  hi           text        not null,
  created_at   timestamptz not null default now(),
  primary key (parent_table, child_name)
);

create table if not exists pgpm.log (
  id           bigint generated always as identity primary key,
  parent_table regclass,
  action       text,
  lo           text,
  hi           text,
  method       text,
  rows         bigint,
  at           timestamptz not null default now()
);

create table if not exists pgpm.dropped_fk (
  id                  bigint generated always as identity primary key,
  parent_table        regclass    not null,
  referencing_table   regclass    not null,
  constraint_name     name        not null,
  definition          text        not null,
  referencing_columns text[]      not null default '{}',
  referenced_columns  text[]      not null default '{}',
  -- true when adopt dropped this FK with p_incoming_fks => 'preserve': the partitioned parent keeps
  -- a unique key matching the FK's referenced columns (the id/uuidv7 happy path), so it can be
  -- re-added verbatim against the parent by restore_incoming_fks once the table is drained. false
  -- (the 'drop' mode) means it needs the composite-FK rebuild via generate_fk_recovery instead.
  restorable          boolean     not null default false,
  -- lifecycle marker for a restorable (preserve-managed) FK: null = currently DROPPED (awaiting
  -- restore), set = currently LIVE on the parent. maintenance keeps the invariant "a managed FK is
  -- live iff the closed tail is empty": it suspends (drops, restored_at -> null) before a drain that
  -- would move referenced rows, and restores (re-adds, restored_at -> now()) once the drain is idle.
  -- This is why the row is kept after restore rather than deleted. Irrelevant for 'drop'-mode rows.
  restored_at         timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate these columns
alter table pgpm.dropped_fk add column if not exists restorable boolean not null default false;
alter table pgpm.dropped_fk add column if not exists restored_at timestamptz;

-- =============================== adapter layer ===============================

-- uuidv7/ULID codec (pure SQL; works on PG 15 -- no native uuidv7() needed):
-- the leading 48 bits are a Unix-ms timestamp, compared byte-wise == time order.
create or replace function pgpm._uuid_to_ts(p_uuid uuid)
returns timestamptz language sql stable as $$
  select to_timestamp(
    ('x' || lpad(substr(replace(p_uuid::text, '-', ''), 1, 12), 16, '0'))::bit(64)::bigint / 1000.0
  );
$$;

create or replace function pgpm._ts_to_uuid(p_ts timestamptz)
returns uuid language sql stable as $$
  select (substr(h,1,8)||'-'||substr(h,9,4)||'-'||substr(h,13,4)||'-'||substr(h,17,4)||'-'||substr(h,21,12))::uuid
  from (select lpad(to_hex(floor(extract(epoch from p_ts) * 1000)::bigint), 12, '0') || repeat('0', 20) as h) s;
$$;

-- native grid type for comparisons: numeric for id, timestamptz otherwise
create or replace function pgpm._native_type(p_kind text)
returns text language sql immutable as $$
  select case when p_kind = 'id' then 'numeric' else 'timestamptz' end;
$$;

create or replace function pgpm._native_gt(p_kind text, a text, b text)
returns boolean language plpgsql immutable as $$
begin
  if p_kind = 'id' then return a::numeric > b::numeric;
  else return a::timestamptz > b::timestamptz; end if;
end;
$$;

-- floor a native value to the partition-grid lower bound
create or replace function pgpm._grid_floor(p_kind text, p_step text, p_anchor text, p_native text)
returns text language plpgsql immutable as $$
declare
  v_months int; v_fixsecs double precision; v_secs double precision;
  k bigint; ts timestamptz; anc timestamptz;
begin
  if p_kind in ('time', 'uuidv7') then
    anc := p_anchor::timestamptz; ts := p_native::timestamptz;
    v_months  := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_fixsecs := extract(epoch from (p_step::interval - make_interval(months => v_months)));
    v_secs    := extract(epoch from p_step::interval);
    if v_months > 0 then
      if v_fixsecs <> 0 then
        raise exception 'pg_partition_magician: mixed month + duration interval unsupported (%)', p_step;
      end if;
      k := ((extract(year from ts) - extract(year from anc)) * 12
          + (extract(month from ts) - extract(month from anc)))::bigint;
      k := (floor(k::numeric / v_months) * v_months)::bigint;
      return (date_trunc('month', anc) + make_interval(months => k::int))::text;
    else
      k := floor(extract(epoch from (ts - anc)) / v_secs)::bigint;
      return (anc + make_interval(secs => k * v_secs))::text;
    end if;
  elsif p_kind = 'id' then
    return (floor((p_native::numeric - p_anchor::numeric) / p_step::numeric) * p_step::numeric + p_anchor::numeric)::text;
  else
    raise exception 'pg_partition_magician: unknown control_kind %', p_kind;
  end if;
end;
$$;

create or replace function pgpm._grid_next(p_kind text, p_step text, p_lo text)
returns text language plpgsql immutable as $$
begin
  if p_kind in ('time', 'uuidv7') then return (p_lo::timestamptz + p_step::interval)::text;
  elsif p_kind = 'id' then return (p_lo::numeric + p_step::numeric)::text;
  else raise exception 'pg_partition_magician: unknown control_kind %', p_kind; end if;
end;
$$;

-- native grid value -> a literal of the COLUMN type
create or replace function pgpm._encode(p_kind text, p_native text)
returns text language plpgsql immutable as $$
begin
  if p_kind = 'uuidv7' then return pgpm._ts_to_uuid(p_native::timestamptz)::text;
  else return p_native; end if;
end;
$$;

-- a stored COLUMN value -> native grid value
create or replace function pgpm._decode(p_kind text, p_colvalue text)
returns text language plpgsql immutable as $$
begin
  if p_colvalue is null then return null; end if;
  if p_kind = 'uuidv7' then return pgpm._uuid_to_ts(p_colvalue::uuid)::text;
  else return p_colvalue; end if;
end;
$$;

create or replace function pgpm._part_name(p_relname name, p_kind text, p_step text, p_lo_native text)
returns name language plpgsql immutable as $$
declare v_months int; v_secs double precision; fmt text;
begin
  if p_kind in ('time', 'uuidv7') then
    v_months := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_secs   := extract(epoch from p_step::interval);
    if    v_months >= 12 and v_months % 12 = 0 then fmt := 'YYYY';
    elsif v_months > 0                          then fmt := 'YYYY_MM';
    elsif v_secs  >= 86400                       then fmt := 'YYYY_MM_DD';
    elsif v_secs  >= 3600                        then fmt := 'YYYY_MM_DD_HH24';
    else                                              fmt := 'YYYY_MM_DD_HH24MI';
    end if;
    return (p_relname || '_p' || to_char(p_lo_native::timestamptz, fmt))::name;
  else
    return (p_relname || '_p' || lpad(floor(p_lo_native::numeric)::text, 19, '0'))::name;
  end if;
end;
$$;

-- the write frontier in native terms: now() (time), max(control) (id/uuidv7)
create or replace function pgpm._frontier_native(p_parent regclass)
returns text language plpgsql as $$
declare cfg pgpm.config; v_max text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if cfg.control_kind = 'time' then return now()::text; end if;
  -- ORDER BY ... LIMIT 1 (not max()) so it works for uuid too; uses the index.
  -- Qualify with an alias so ORDER BY binds to the (typed) column, not the ::text projection.
  execute format('select t.%I::text from %s t order by t.%I desc limit 1',
                 cfg.control_column, p_parent::text, cfg.control_column) into v_max;
  if v_max is null then
    return case when cfg.control_kind = 'id' then cfg.partition_anchor else now()::text end;
  end if;
  return pgpm._decode(cfg.control_kind, v_max);
end;
$$;

-- ============================== engine ==============================

-- create an EMPTY partition for native [p_lo, p_hi); skips the DEFAULT scan when
-- the default is non-empty (NOT VALID exclusion CHECK + VALIDATE).
create or replace function pgpm._create_partition(
  p_cfg pgpm.config, p_nsp name, p_rel name, p_default regclass, p_name name, p_lo text, p_hi text
)
returns void language plpgsql as $$
declare v_empty boolean; v_excl name; v_method text; v_lo_lit text; v_hi_lit text;
begin
  v_lo_lit := pgpm._encode(p_cfg.control_kind, p_lo);
  v_hi_lit := pgpm._encode(p_cfg.control_kind, p_hi);
  if p_cfg.keep_default then
    execute format('select not exists (select 1 from %s)', p_default::text) into v_empty;
  else v_empty := true; end if;

  if v_empty then
    execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                   p_nsp, p_name, p_nsp, p_rel, v_lo_lit, v_hi_lit);
    v_method := 'plain';
  else
    v_excl := (p_name || '_excl')::name;
    execute format('alter table %s add constraint %I check (%I < %L or %I >= %L) not valid',
                   p_default::text, v_excl, p_cfg.control_column, v_lo_lit, p_cfg.control_column, v_hi_lit);
    execute format('alter table %s validate constraint %I', p_default::text, v_excl);
    execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                   p_nsp, p_name, p_nsp, p_rel, v_lo_lit, v_hi_lit);
    execute format('alter table %s drop constraint %I', p_default::text, v_excl);
    v_method := 'check_skip';
  end if;

  insert into pgpm.part (parent_table, child_name, lo, hi)
    values (format('%I.%I', p_nsp, p_rel)::regclass, p_name, p_lo, p_hi) on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'premake', p_lo, p_hi, v_method);
end;
$$;

create or replace function pgpm.premake(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_default regclass;
  v_frontier text; v_lo text; v_hi text; v_lo_lit text; v_hi_lit text; v_name name;
  v_has boolean; v_made int := 0; k int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_default  := format('%I.%I', v_nsp, cfg.default_table)::regclass;
  v_frontier := pgpm._frontier_native(p_parent);
  v_lo       := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);

  for k in 0 .. cfg.premake loop
    if k > 0 then v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo); end if;
    v_hi   := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
    v_name := pgpm._part_name(v_rel, cfg.control_kind, cfg.partition_step, v_lo);
    continue when to_regclass(format('%I.%I', v_nsp, v_name)) is not null;
    v_lo_lit := pgpm._encode(cfg.control_kind, v_lo);
    v_hi_lit := pgpm._encode(cfg.control_kind, v_hi);
    -- skip a range the DEFAULT still holds data for (only the active interval)
    execute format('select exists (select 1 from %s where %I >= %L and %I < %L)',
                   v_default::text, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit) into v_has;
    continue when v_has;
    perform pgpm._create_partition(cfg, v_nsp, v_rel, v_default, v_name, v_lo, v_hi);
    v_made := v_made + 1;
  end loop;
  return v_made;
end;
$$;

create or replace function pgpm.drain_step(
  p_parent regclass, p_batch int default null, p_include_open boolean default false
)
returns text language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_def text; v_cols text; v_batch int;
  v_min text; v_min_native text; v_lo text; v_hi text; v_lo_lit text; v_hi_lit text;
  v_name name; v_open boolean; v_frontier text; v_moved bigint; v_more boolean;
  v_excl name; v_method text; v_reltuples real; v_avg numeric; v_blk_limit int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_def   := format('%I.%I', v_nsp, cfg.default_table);
  v_batch := coalesce(p_batch, cfg.drain_batch, 5000);

  -- Block budget (DESIGN.md sec 8): bound the microbatch by heap+TOAST blocks, not just rows, so a
  -- wide-row table (large jsonb/bytea) can't make one batch tens of GB. Translate the budget to a
  -- row cap via the default's average bytes/row (pg_table_size / reltuples) and take the smaller of
  -- the two. Skipped when unset, or when stats are missing (reltuples <= 0): then it is the row cap.
  if cfg.drain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_def::regclass;
    if coalesce(v_reltuples, 0) > 0 then
      v_avg := pg_table_size(v_def::regclass)::numeric / v_reltuples;   -- avg heap+TOAST bytes/row
      if v_avg > 0 then
        v_blk_limit := greatest(1, floor(cfg.drain_max_blocks::numeric * 8192 / v_avg))::int;
        v_batch := least(v_batch, v_blk_limit);
      end if;
    end if;
  end if;

  execute format('select t.%I::text from %s t order by t.%I asc limit 1',
                 cfg.control_column, v_def, cfg.control_column) into v_min;
  if v_min is null then return 'idle'; end if;

  v_min_native := pgpm._decode(cfg.control_kind, v_min);
  v_lo := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_min_native);
  v_hi := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
  v_frontier := pgpm._frontier_native(p_parent);
  v_open := pgpm._native_gt(cfg.control_kind, v_hi, v_frontier);
  if v_open and not p_include_open then return 'idle'; end if;

  v_name   := pgpm._part_name(v_rel, cfg.control_kind, cfg.partition_step, v_lo);
  v_lo_lit := pgpm._encode(cfg.control_kind, v_lo);
  v_hi_lit := pgpm._encode(cfg.control_kind, v_hi);

  if to_regclass(format('%I.%I', v_nsp, v_name)) is null then
    execute format('create table %I.%I (like %I.%I including defaults including indexes including constraints excluding identity)',
                   v_nsp, v_name, v_nsp, v_rel);
    execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                   v_nsp, v_name, (v_name || '_ck'), cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
  end if;

  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped;

  -- ORDER BY the control column: the default's PK leads with the control column (adopt builds
  -- it that way), so this makes the batch select an INDEX SCAN that reads exactly p_batch rows
  -- in order. Without it the planner SEQ-SCANs the (large) default to find a batch -- every
  -- drain_step re-scanning the whole default, a SEQUENTIAL_SCAN_STORM at scale. The index scan
  -- also needs no sort. (The per-batch temp spill is the data-modifying CTE below materializing
  -- the moved rows -- it is independent of this ORDER BY.)
  execute format($f$
    with b as (
      delete from %1$s where ctid in (select ctid from %1$s
                       where %2$I >= %3$L and %2$I < %4$L order by %2$I limit %5$s)
      returning %6$s
    )
    insert into %7$I.%8$I (%6$s) select %6$s from b
  $f$, v_def, cfg.control_column, v_lo_lit, v_hi_lit, v_batch, v_cols, v_nsp, v_name);
  get diagnostics v_moved = row_count;
  insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'drain_move', v_lo, v_hi, v_moved);

  -- Does ANY row remain in [lo,hi)? Use EXISTS (index scan, stops at the first row), NOT
  -- count(*), which re-scans the whole range every microbatch -- O(rows^2/batch), and while
  -- the default isn't all-visible mid-drain it seq-scans the range each step (a
  -- SEQUENTIAL_SCAN_STORM at scale). We only need to know whether to keep draining or attach.
  execute format('select exists(select 1 from %s where %I >= %L and %I < %L)',
                 v_def, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit) into v_more;
  if v_more then return 'moved:' || v_moved; end if;

  if v_open or not cfg.keep_default then
    execute format('alter table %I.%I attach partition %I.%I for values from (%L) to (%L)',
                   v_nsp, v_rel, v_nsp, v_name, v_lo_lit, v_hi_lit);
    v_method := 'plain';
  else
    v_excl := (v_name || '_excl')::name;
    execute format('alter table %s add constraint %I check (%I < %L or %I >= %L) not valid',
                   v_def, v_excl, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
    execute format('alter table %s validate constraint %I', v_def, v_excl);
    execute format('alter table %I.%I attach partition %I.%I for values from (%L) to (%L)',
                   v_nsp, v_rel, v_nsp, v_name, v_lo_lit, v_hi_lit);
    execute format('alter table %s drop constraint %I', v_def, v_excl);
    v_method := 'check_skip';
  end if;
  insert into pgpm.part (parent_table, child_name, lo, hi) values (p_parent, v_name, v_lo, v_hi) on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'drain_attach', v_lo, v_hi, v_method);
  return 'attached:' || v_name || ':' || v_method;
end;
$$;

create or replace function pgpm.drain_all(
  p_parent regclass, p_batch int default null, p_include_open boolean default false
)
returns int language plpgsql as $$
declare v_status text; v_iter int := 0;
begin
  -- Suspend any live preserve-managed FK before draining: moving referenced rows past a live
  -- CASCADE/SET NULL FK would silently mutate the referencing side (a NO ACTION FK would block). A
  -- no-op unless a managed FK is live with closed-tail work. drain_all stays a pure drainer otherwise;
  -- restoration is left to maintenance or an explicit restore_incoming_fks call.
  perform pgpm.suspend_incoming_fks(p_parent);
  loop
    v_status := pgpm.drain_step(p_parent, p_batch, p_include_open);
    exit when v_status = 'idle';
    v_iter := v_iter + 1;
    if v_iter > 1000000 then raise exception 'pg_partition_magician: drain_all safety limit'; end if;
  end loop;
  return v_iter;
end;
$$;

create or replace function pgpm.retention(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_boundary text; v_frontier text; v_ncast text; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retention is null then return 0; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  if cfg.control_kind = 'id' then
    v_frontier := pgpm._frontier_native(p_parent);
    v_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   (v_frontier::numeric - cfg.retention::numeric)::text);
  else
    v_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   (now() - cfg.retention::interval)::text);
  end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast)
  loop
    execute format('drop table %I.%I', v_nsp, r.child_name);
    delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi) values (p_parent, 'retention_drop', r.lo, r.hi);
    v_dropped := v_dropped + 1;
  end loop;
  return v_dropped;
end;
$$;

-- ============================== adopt ==============================

create or replace function pgpm._adopt(
  p_parent regclass, p_control name, p_control_kind text,
  p_step text, p_anchor text, p_premake int, p_retention text,
  p_keep_default boolean, p_drain_batch int, p_paused boolean, p_incoming_fks text
)
returns regclass language plpgsql as $$
declare
  v_nsp name; v_rel name; v_default name; v_defreg regclass; v_parent regclass;
  v_typname text; v_oldpk text[]; v_pkcols text[]; v_idcols name[]; v_pkname name; v_col name;
  v_idx_names text[]; v_idx_defs text[]; v_skipped int; v_old name; v_new name; v_pdef text; j int;
  v_fk record; v_dropped jsonb := '[]'::jsonb; v_e jsonb; v_fk_eligible boolean;
  v_uchk_n bigint; v_uchk_frac numeric; v_prebuilt name; v_pk_reuse boolean := false;
  v_idmax bigint[]; v_m bigint; v_i int;
begin
  if p_control_kind not in ('time', 'id', 'uuidv7') then
    raise exception 'pg_partition_magician: unknown control_kind %', p_control_kind;
  end if;
  if p_incoming_fks not in ('error', 'drop', 'preserve') then
    raise exception 'pg_partition_magician: p_incoming_fks must be ''error'', ''drop'', or ''preserve'' (got %)', p_incoming_fks;
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_default := (v_rel || '_default')::name;

  -- control column type vs kind (and the float guard)
  select t.typname into v_typname
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  if v_typname is null then
    raise exception 'pg_partition_magician: column % not found on %', p_control, p_parent;
  end if;
  if p_control_kind = 'time' and v_typname not in ('timestamptz', 'timestamp', 'date') then
    raise exception 'pg_partition_magician: control_kind time needs a timestamp/date column (got %)', v_typname;
  elsif p_control_kind = 'id' then
    if v_typname in ('float4', 'float8') then
      raise exception 'pg_partition_magician: float/double control columns are unsupported (imprecise boundaries; NaN/Inf poison the frontier) -- use bigint or numeric';
    elsif v_typname not in ('int2', 'int4', 'int8', 'numeric') then
      raise exception 'pg_partition_magician: control_kind id needs an integer or numeric column (got %)', v_typname;
    end if;
  elsif p_control_kind = 'uuidv7' and v_typname <> 'uuid' then
    raise exception 'pg_partition_magician: control_kind uuidv7 needs a uuid column (got %)', v_typname;
  end if;

  -- Orphaned-child guard (DESIGN.md sec 8): a drain creates each child partition as a standalone
  -- table (CREATE TABLE ... LIKE) and only ATTACHes it at the END of that child's drain. An
  -- interrupted drain therefore leaves an un-attached child -- which DROP TABLE <parent> CASCADE
  -- does NOT remove (an un-attached table has no dependency on the parent). If the table is later
  -- recreated/reloaded and re-adopted, the next drain reuses the orphan by name and INSERTs rows
  -- whose keys already live in it: a cryptic mid-drain "duplicate key" deep inside drain_step.
  -- Refuse up front -- any standalone (un-attached) table in this schema whose name matches this
  -- parent's child-partition naming (<rel>_p<digits...>) is an orphan. starts_with handles the
  -- (un-escaped) rel prefix; the regex only constrains the data-independent suffix.
  declare v_orphan name;
  begin
    select c.relname into v_orphan
      from pg_class c
     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
       and c.relkind = 'r'
       and starts_with(c.relname, v_rel || '_p')
       and case when p_control_kind = 'id'
                then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
                else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
           end
       and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
     limit 1;
    if v_orphan is not null then
      raise exception 'pg_partition_magician: %.% already exists as a standalone table matching this parent''s partition naming -- most likely an orphan left by an interrupted drain. Drop it (drop table %.%) and retry adopt.',
        v_nsp, v_orphan, quote_ident(v_nsp), quote_ident(v_orphan);
    end if;
  end;

  -- uuidv7 sanity check: the type can't tell us the values are time-ordered, so
  -- sample them -- random (UUIDv4) columns decode to implausible timestamps.
  if p_control_kind = 'uuidv7' then
    select sampled, fraction into v_uchk_n, v_uchk_frac from pgpm.check_uuidv7(p_parent, p_control, 1000);
    if coalesce(v_uchk_n, 0) > 0 and v_uchk_frac < 0.95 then
      raise notice 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps; the column may be random (UUIDv4) rather than time-ordered (UUIDv7/ULID) -- partitioning will misbehave. Proceeding; verify with pgpm.check_uuidv7().',
        (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
    end if;
  end if;

  -- existing PK columns and identity columns
  select array_agg(a.attname::text order by k.ord) into v_oldpk
    from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = p_parent and con.contype = 'p';
  select conname into v_pkname from pg_constraint where conrelid = p_parent and contype = 'p';
  select array_agg(a.attname order by a.attnum) into v_idcols
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a','d') and not a.attisdropped;

  -- Capture max(identity) NOW, while the table's ORIGINAL indexes still exist. We drop the old PK
  -- below (step 2) and swap to the composite (control, id) PK (step 4); after that the only index
  -- covering the identity column no longer leads with it, so a later max(id) would seq-scan the
  -- whole (large) DEFAULT under adopt's ACCESS EXCLUSIVE lock -- turning the metadata-only cutover
  -- into an O(rows) blocking operation (minutes on a 100GB+ table). Here, with the original id PK
  -- index intact, it is an index lookup. The captured value advances the (freshly recreated) parent
  -- identity sequence in step 8b. (Falls back to whatever plan the original indexes allow if the
  -- identity column wasn't index-leading -- no worse than before, and index-fast in the common case.)
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select coalesce(max(%I), 0)::bigint from %s', v_col, p_parent::text) into v_m;
      v_idmax := array_append(v_idmax, v_m);
    end loop;
  end if;

  -- new PK columns: partition key first, then the rest of the old PK
  if v_oldpk is not null then
    v_pkcols := array[p_control::text] || array(select x from unnest(v_oldpk) x where x <> p_control::text);
    -- If the new PK equals the existing PK in the same order, the partition key is already covered
    -- by the PK (partitioning on a monotonic id, a uuidv7/ULID key, or a PK already led by the
    -- control column). Keep and REUSE the existing index instead of dropping and rebuilding an
    -- identical one: step 2's drop and step 4's build are skipped, and step 8's parent PRIMARY KEY
    -- reconciles the existing index in place (no O(rows) build). See DESIGN.md section 8.
    v_pk_reuse := (v_pkcols = v_oldpk);
  end if;

  -- secondary (non-PK, non-unique) indexes to recreate on the parent
  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid)) into v_idx_names, v_idx_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary and not i.indisunique;
  -- count unique secondary indexes we can't carry over -- but EXCLUDE a pre-built
  -- index whose columns match the new PK (pgpm.build_pk_concurrently's index, promoted in step 4).
  select count(*) into v_skipped from pg_index i
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
     and (v_pkcols is null or (select array_agg(a.attname::text order by k.ord)
            from unnest(i.indkey) with ordinality as k(attnum, ord)
            join pg_attribute a on a.attrelid = p_parent and a.attnum = k.attnum) is distinct from v_pkcols);
  if v_skipped > 0 then
    raise notice 'pg_partition_magician: skipped % unique secondary index(es) on %; recreate on the parent manually (must include the partition key)', v_skipped, p_parent;
  end if;

  -- 0. incoming FKs (capture before the rename; record after the new parent exists)
  if exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    if p_incoming_fks = 'error' then
      raise exception
        'pg_partition_magician: % has incoming foreign key(s) (%). If the partition key is the referenced key (the id/uuidv7 case), keep them with p_incoming_fks => ''preserve''; otherwise the PK widens and they must become composite FKs (p_incoming_fks => ''drop'', then generate_fk_recovery).',
        p_parent,
        (select string_agg(conname || ' on ' || conrelid::regclass::text, ', ')
           from pg_constraint where confrelid = p_parent and contype = 'f');
    else
      for v_fk in
        select c.conrelid::regclass as reltbl, c.conname, pg_get_constraintdef(c.oid) as def,
               (select array_agg(a.attname::text order by k.ord) from unnest(c.conkey) with ordinality as k(attnum, ord)
                  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as lcols,
               (select array_agg(a.attname::text order by k.ord) from unnest(c.confkey) with ordinality as k(attnum, ord)
                  join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
          from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
      loop
        -- Eligible to PRESERVE iff the partitioned parent will keep a unique key on EXACTLY this
        -- FK's referenced columns. That key is the parent's PK (v_pkcols); on the id/uuidv7 happy
        -- path it is the single partition-key column, so a single-column FK to it survives verbatim.
        -- In the widening (time) case v_pkcols gains the partition key, no single-column unique
        -- remains, and the FK can only become composite (generate_fk_recovery).
        v_fk_eligible := v_pkcols is not null
          and (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            = (select array_agg(x order by x) from unnest(v_pkcols) x);
        if p_incoming_fks = 'preserve' and not v_fk_eligible then
          raise exception 'pg_partition_magician: cannot preserve incoming FK % on % -- it references (%), but the partitioned parent will keep a unique key only on (%). Re-point it as a composite FK instead (p_incoming_fks => ''drop'', then generate_fk_recovery).',
            v_fk.conname, v_fk.reltbl, array_to_string(v_fk.rcols, ', '), array_to_string(coalesce(v_pkcols, '{}'), ', ');
        end if;
        v_dropped := v_dropped || jsonb_build_object(
          'reltbl', v_fk.reltbl::text, 'conname', v_fk.conname::text, 'def', v_fk.def,
          'lcols', to_jsonb(v_fk.lcols), 'rcols', to_jsonb(v_fk.rcols),
          'restorable', (p_incoming_fks = 'preserve'));
        execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
      end loop;
    end if;
  end if;

  -- 1. rename the live table to the DEFAULT partition name
  execute format('alter table %s rename to %I', p_parent::text, v_default);
  v_defreg := format('%I.%I', v_nsp, v_default)::regclass;

  -- 2. drop the old (sub-)PK -- UNLESS the partition key is already covered by it (v_pk_reuse): then
  -- keep it and reuse its index in place (step 4 is skipped; step 8's parent PK reconciles it).
  if v_pkname is not null and not v_pk_reuse then
    execute format('alter table %s drop constraint %I', v_defreg::text, v_pkname);
  end if;

  -- 3. drop identity on the default; key columns NOT NULL
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I drop identity if exists', v_defreg::text, v_col);
    end loop;
  end if;
  execute format('alter table %s alter column %I set not null', v_defreg::text, p_control);
  if v_pkcols is not null then
    foreach v_col in array v_pkcols loop
      execute format('alter table %s alter column %I set not null', v_defreg::text, v_col);
    end loop;
  end if;

  -- 4. establish the default's PK on (partition key, rest of old PK). If a matching
  -- unique index was pre-built online (pgpm.build_pk_concurrently -> CREATE UNIQUE INDEX
  -- CONCURRENTLY, run by the operator before adopt), promote THAT -- a metadata-only
  -- step, so adopt holds its ACCESS EXCLUSIVE lock only briefly. Otherwise build the
  -- index in-transaction: correct, but O(rows) under the lock (fine for small tables,
  -- a multi-minute write-blocking window on very large ones -- prefer build_pk_concurrently).
  -- Skipped entirely when v_pk_reuse: the default kept its original PK in step 2.
  if v_pkcols is not null and not v_pk_reuse then
    select c.relname into v_prebuilt
      from pg_index i join pg_class c on c.oid = i.indexrelid
     where i.indrelid = v_defreg and i.indisunique and i.indisvalid and not i.indisprimary
       and i.indpred is null and i.indexprs is null
       and (select array_agg(a.attname::text order by k.ord)
              from unnest(i.indkey) with ordinality as k(attnum, ord)
              join pg_attribute a on a.attrelid = v_defreg and a.attnum = k.attnum) = v_pkcols
     limit 1;
    if v_prebuilt is null then
      v_prebuilt := (v_default || '_pk_tmp')::name;
      execute format('create unique index %I on %s (%s)', v_prebuilt, v_defreg::text,
                     (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
    else
      raise notice 'pg_partition_magician: reusing pre-built unique index % as the PK (adopt stays metadata-only)', v_prebuilt;
    end if;
    execute format('alter table %s add constraint %I primary key using index %I',
                   v_defreg::text, (v_default || '_pkey'), v_prebuilt);
  end if;

  -- 5. create the partitioned parent under the original name (no PK yet)
  execute format('create table %I.%I (like %s including defaults including generated) partition by range (%I)',
                 v_nsp, v_rel, v_defreg::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_rel)::regclass;

  -- 6. re-establish identity on the parent
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I add generated by default as identity', v_parent::text, v_col);
    end loop;
  end if;

  -- 7. attach the existing table as the DEFAULT partition
  execute format('alter table %s attach partition %s default', v_parent::text, v_defreg::text);

  -- 8. parent PRIMARY KEY -- reuses the default's promoted PK index (no rebuild)
  if v_pkcols is not null then
    execute format('alter table %s add primary key (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  end if;

  -- 8b. advance each identity sequence past the largest existing value -- using the max captured
  -- up front (index lookup), NOT a fresh max() here (which would seq-scan the default now that the
  -- id-leading index is gone). The parent's identity sequence was freshly created in step 6, so
  -- this advance is REQUIRED: without it the next insert would collide at id = 1.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_parent::text, v_idcols[v_i], v_idmax[v_i] + 1);
    end loop;
  end if;

  -- 9. keep autovacuum ahead on the default during the drain
  execute format('alter table %s set ('
              || 'autovacuum_vacuum_scale_factor = 0.0, autovacuum_vacuum_threshold = 1000, '
              || 'autovacuum_analyze_scale_factor = 0.0, autovacuum_analyze_threshold = 1000, '
              || 'autovacuum_vacuum_cost_limit = 2000, autovacuum_vacuum_cost_delay = 2)', v_defreg::text);

  -- 9b. recreate secondary indexes as partitioned indexes, attaching the default's
  if v_idx_names is not null then
    for j in 1 .. array_length(v_idx_names, 1) loop
      v_old  := v_idx_names[j]::name;
      v_new  := (v_old || '_pgpm')::name;
      v_pdef := regexp_replace(v_idx_defs[j], '^CREATE INDEX \S+ ON ',
                               'CREATE INDEX ' || quote_ident(v_new) || ' ON ONLY ');
      execute v_pdef;
      execute format('alter index %I.%I attach partition %I.%I', v_nsp, v_new, v_nsp, v_old);
    end loop;
  end if;

  -- 10. register
  insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                           premake, retention, keep_default, drain_batch, default_table, paused)
  values (v_parent, p_control, p_control_kind, p_step, p_anchor, p_premake, p_retention,
          p_keep_default, p_drain_batch, v_default, p_paused)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, control_kind = excluded.control_kind,
    partition_step = excluded.partition_step, partition_anchor = excluded.partition_anchor,
    premake = excluded.premake, retention = excluded.retention, keep_default = excluded.keep_default,
    drain_batch = excluded.drain_batch, default_table = excluded.default_table, paused = excluded.paused;

  insert into pgpm.log (parent_table, action) values (v_parent, 'adopt');

  -- record any dropped incoming FKs (now pointing at the new parent)
  for v_e in select value from jsonb_array_elements(v_dropped) loop
    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition,
                                 referencing_columns, referenced_columns, restorable)
    values (v_parent, (v_e->>'reltbl')::regclass, v_e->>'conname', v_e->>'def',
            array(select jsonb_array_elements_text(v_e->'lcols')),
            array(select jsonb_array_elements_text(v_e->'rcols')),
            coalesce((v_e->>'restorable')::boolean, false));
    insert into pgpm.log (parent_table, action, method) values (v_parent, 'drop_incoming_fk', v_e->>'conname');
  end loop;

  -- NOTE: premake is intentionally NOT run inside adopt. It attaches future partitions,
  -- and attaching a partition to a parent whose DEFAULT already holds data makes Postgres
  -- scan the default -- which, inside this ACCESS EXCLUSIVE transaction, blocks ALL access
  -- for the whole scan (O(default), minutes on a large table). adopt() therefore does the
  -- metadata-only cutover ONLY (a fresh parent with just the DEFAULT attached scans nothing),
  -- so it stays online even at scale. Run pgpm.premake(parent) (or pgpm.maintenance, or the
  -- scheduled maintenance job) AFTER adopt to build the future partitions online -- its
  -- VALIDATE scans then run under a non-blocking SHARE UPDATE EXCLUSIVE lock. Until premake
  -- runs, new writes route to the DEFAULT (correct, just not yet split into future cells).
  return v_parent;
end;
$$;

-- build_pk_concurrently: build the default's composite PK index ONLINE before adopt,
-- so the adopt cutover stays metadata-only. Building it inside adopt() would be O(rows)
-- under ACCESS EXCLUSIVE -- a multi-minute write-blocking window on a large table.
-- CREATE INDEX CONCURRENTLY can't run inside a function/procedure, but it CAN run from
-- a pg_cron background worker (pgpm already requires pg_cron) -- so this schedules the
-- CIC as a cron job, polls until the index is valid (committing between polls to see
-- the worker's progress), then unschedules. The operator just calls this, then adopt()
-- -- which finds the pre-built index by its columns and promotes it. No DDL hand-off.
--   call pgpm.build_pk_concurrently('public.events','created_at');
--   select pgpm.adopt('public.events','created_at', interval '1 month');
create or replace procedure pgpm.build_pk_concurrently(
  p_parent regclass, p_control name, p_timeout interval default '6 hours', p_poll interval default '5 seconds'
) language plpgsql as $$
declare
  v_nsp name; v_rel name; v_oldpk text[]; v_pkcols text[]; v_idxname name; v_cols text;
  v_idreg regclass; v_job text; v_deadline timestamptz; v_valid boolean; v_status text; v_msg text;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select array_agg(a.attname::text order by k.ord) into v_oldpk
    from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = p_parent and con.contype = 'p';
  if v_oldpk is null then
    raise notice 'pg_partition_magician: % has no primary key; adopt() builds none -- nothing to pre-build', p_parent;
    return;
  end if;
  -- same PK derivation as _adopt: partition key first, then the rest of the old PK
  v_pkcols  := array[p_control::text] || array(select x from unnest(v_oldpk) x where x <> p_control::text);
  v_idxname := (v_rel || '_pgpm_pkey_pre')::name;
  v_cols    := (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x);

  v_idreg := to_regclass(format('%I.%I', v_nsp, v_idxname));
  if v_idreg is not null and (select indisvalid from pg_index where indexrelid = v_idreg) then
    raise notice 'pg_partition_magician: %.% already built and valid -- run adopt() next', v_nsp, v_idxname;
    return;
  elsif v_idreg is not null then
    execute format('drop index if exists %I.%I', v_nsp, v_idxname);  -- invalid leftover from a prior attempt
  end if;

  -- CIC from a pg_cron worker (top-level, so it's allowed). IF NOT EXISTS makes re-fires
  -- no-ops; we unschedule the moment the index goes valid.
  v_job := 'pgpm_build_' || v_nsp || '_' || v_rel;
  perform cron.unschedule(jobid) from cron.job where jobname = v_job;
  -- pg_cron's sub-minute form is 'N seconds' (not an interval's '00:00:05' text)
  perform cron.schedule(v_job, format('%s seconds', greatest(1, extract(epoch from p_poll)::int)),
    format('create unique index concurrently if not exists %I on %I.%I (%s)', v_idxname, v_nsp, v_rel, v_cols));
  raise notice 'pg_partition_magician: building % concurrently via pg_cron job % ...', v_idxname, v_job;

  v_deadline := clock_timestamp() + p_timeout;
  loop
    commit;                       -- observe the cron worker's committed catalog changes
    perform pg_sleep(extract(epoch from p_poll));
    v_idreg := to_regclass(format('%I.%I', v_nsp, v_idxname));
    if v_idreg is not null then
      select indisvalid into v_valid from pg_index where indexrelid = v_idreg;
      exit when v_valid;
    end if;
    select status, return_message into v_status, v_msg from cron.job_run_details
      where jobid = (select jobid from cron.job where jobname = v_job)
      order by start_time desc limit 1;
    if v_status = 'failed' and coalesce(v_msg, '') not ilike '%already exists%' then
      perform cron.unschedule(jobid) from cron.job where jobname = v_job;
      raise exception 'pg_partition_magician: concurrent index build failed: %', v_msg;
    end if;
    if clock_timestamp() > v_deadline then
      perform cron.unschedule(jobid) from cron.job where jobname = v_job;
      raise exception 'pg_partition_magician: concurrent index build did not finish within %', p_timeout;
    end if;
  end loop;
  perform cron.unschedule(jobid) from cron.job where jobname = v_job;
  raise notice 'pg_partition_magician: % is valid -- run adopt() now (it reuses this index, metadata-only)', v_idxname;
end;
$$;

-- typed entry points (thin wrappers over _adopt)
create or replace function pgpm.adopt(
  p_parent regclass, p_control name, p_interval interval,
  p_premake int default 4, p_retention interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass language sql as $$
  select pgpm._adopt(p_parent, p_control, 'time', p_interval::text, p_anchor::text, p_premake,
                     p_retention::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks);
$$;

create or replace function pgpm.adopt_by_id(
  p_parent regclass, p_control name, p_step bigint,
  p_premake int default 4, p_retention bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass language sql as $$
  select pgpm._adopt(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_premake,
                     p_retention::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks);
$$;

create or replace function pgpm.adopt_by_uuidv7(
  p_parent regclass, p_control name, p_interval interval,
  p_premake int default 4, p_retention interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass language sql as $$
  select pgpm._adopt(p_parent, p_control, 'uuidv7', p_interval::text, p_anchor::text, p_premake,
                     p_retention::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks);
$$;

-- ============================== maintenance / observability ==============================

create or replace function pgpm.maintenance(p_parent regclass)
returns text language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0; v_dropped int := 0; v_drain text := 'skipped'; v_restored int := 0; v_suspended int := 0;
  v_note text := '';
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then return 'paused'; end if;

  -- Maintenance is a background janitor; it must NEVER block -- let alone deadlock -- the live
  -- workload. Each step is isolated in its own subtransaction, and a step that loses a lock race
  -- is DEFERRED (retried next tick) WITHOUT aborting the drain.
  --
  -- premake/retention get a VERY SHORT lock_timeout. Premaking a future partition's first step
  -- (ADD CONSTRAINT on the default, for the scan-skip path) takes ACCESS EXCLUSIVE on the default
  -- -- which the live workload's inserts hold almost continuously. A long timeout there is doubly
  -- bad: it blocks the workload for the whole wait (the pending ACCESS EXCLUSIVE queues every new
  -- locker behind it), AND if it does win the lock it goes on to VALIDATE-scan the entire default
  -- before the CREATE -- a scan that is wasted whenever the CREATE then can't get its lock. Failing
  -- fast makes a deferral nearly free: no long block, and it bails before that scan. premake is
  -- optional (the future cells aren't written yet; the DEFAULT catches anything), so it simply
  -- retries when the workload next has a gap.
  perform set_config('lock_timeout', '200ms', true);

  -- premake back-off: once a deferral happens, don't retry every tick -- under sustained write
  -- contention premake can't win the lock for minutes, and each attempt risks a wasted default
  -- scan. Wait out a back-off window; the future cells aren't written yet (the DEFAULT catches
  -- them), so deferring premake is harmless. A successful premake clears the back-off.
  if coalesce(cfg.premake_retry_after, '-infinity'::timestamptz) <= clock_timestamp() then
    begin
      v_made := pgpm.premake(p_parent);
      if cfg.premake_retry_after is not null then
        update pgpm.config set premake_retry_after = null where parent_table = p_parent;
      end if;
    exception when others then
      v_note := v_note || ' premake_deferred';
      update pgpm.config set premake_retry_after = clock_timestamp() + interval '30 seconds'
        where parent_table = p_parent;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'premake_skip', left(sqlerrm, 200));
    end;
  else
    v_note := v_note || ' premake_backoff';
  end if;

  begin
    v_dropped := pgpm.retention(p_parent);
  exception when others then
    v_note := v_note || ' retention_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'retention_skip', left(sqlerrm, 200));
  end;

  -- The drain IS the conversion: give its (infrequent) partition attach room to win its lock,
  -- so progress isn't starved. Its scans run under SHARE UPDATE EXCLUSIVE (non-blocking to the
  -- workload); only the brief final ATTACH needs a stronger lock.
  perform set_config('lock_timeout', '3s', true);
  begin
    -- Suspend (re-drop) any preserve-managed FK that is currently live BEFORE draining: the drain
    -- moves referenced rows out of the parent through an un-attached child, which a live NO ACTION FK
    -- blocks and a live CASCADE/SET NULL FK silently honours (deleting/nulling the referencing rows).
    -- suspend_incoming_fks is a no-op when the closed tail is empty. It shares this subtransaction with
    -- the drain on purpose: if it cannot drop a live FK, the drain_step below never runs (the whole
    -- block rolls back), so the drain never moves rows past a live FK -- it just defers and retries.
    v_suspended := pgpm.suspend_incoming_fks(p_parent);
    v_drain := pgpm.drain_step(p_parent);
  exception when others then
    v_drain := 'deferred';
    v_note := v_note || ' drain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'drain_skip', left(sqlerrm, 200));
  end;

  -- Once the closed tail is drained, re-add any incoming FKs that adopt(..., 'preserve') dropped, now
  -- against the new parent. restore_incoming_fks self-gates on quiescence (no closed rows, no in-flight
  -- child), so it is a no-op until the drain is idle and harmless to attempt every tick. Isolated like
  -- the steps above: a hiccup here never aborts the drain's progress.
  begin
    v_restored := pgpm.restore_incoming_fks(p_parent);
  exception when others then
    v_note := v_note || ' restore_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_fk_skip', left(sqlerrm, 200));
  end;

  return format('premade=%s dropped=%s drain=%s suspended_fk=%s restored_fk=%s%s',
                v_made, v_dropped, v_drain, v_suspended, v_restored, v_note);
end;
$$;

create or replace procedure pgpm.maintenance_all()
language plpgsql as $$
declare r record;
begin
  for r in select parent_table from pgpm.config loop
    perform pgpm.maintenance(r.parent_table);
  end loop;
end;
$$;

create or replace function pgpm.check_default(p_parent regclass)
returns table (default_rows bigint, closed_rows bigint, oldest text)
language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_def text; v_cur_lit text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_def     := format('%I.%I', v_nsp, cfg.default_table);
  v_cur_lit := pgpm._encode(cfg.control_kind,
                 pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  pgpm._frontier_native(p_parent)));
  return query execute format(
    'select count(*)::bigint, count(*) filter (where %I < %L)::bigint, (select t.%I::text from %s t order by t.%I limit 1) from %s',
    cfg.control_column, v_cur_lit, cfg.control_column, v_def, cfg.control_column, v_def);
end;
$$;

-- check_uuidv7(): sanity-sample a uuid column. Genuine UUIDv7/ULID values decode
-- (via their leading 48-bit ms prefix) to plausible recent timestamps and score
-- ~1.0; random UUIDv4 columns score near 0. A heuristic, not a proof.
create or replace function pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select pgpm._uuid_to_ts(%I) as ts from %s limit %s)
    select count(*)::bigint,
           count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::bigint,
           round(coalesce(count(*) filter (where ts between timestamptz '2015-01-01' and now() + interval '1 day')::numeric
                          / nullif(count(*), 0), 0), 4),
           min(ts), max(ts)
    from s
  $q$, p_control, p_table::text, p_sample);
end;
$$;

-- check_time_monotonic: how co-monotonic is an id column with a timestamp column? Samples p_sample
-- rows at random, orders them by the id, and reports the fraction of adjacent pairs whose time is
-- non-decreasing. ~1.0 means id and time co-increase; backfills and out-of-order arrival drive it
-- down. This is the tier-2 safety check for time-based retention expressed against an id partition
-- key (DESIGN.md section 8): mapping "older than T" to an id boundary is only sound when id and
-- time co-increase. Heuristic, not a proof -- mirrors check_uuidv7's plausibility sampling.
create or replace function pgpm.check_time_monotonic(
  p_table regclass, p_id name, p_time name, p_sample int default 1000
) returns table (sampled bigint, monotonic bigint, fraction numeric)
language plpgsql as $$
begin
  return query execute format($q$
    with s as (select %2$I::timestamptz as t, %1$I as idv from %3$s order by random() limit %4$s),
         o as (select t, lag(t) over (order by idv) as prev from s)
    select count(*) filter (where prev is not null)::bigint,
           count(*) filter (where prev is not null and t >= prev)::bigint,
           round(coalesce(count(*) filter (where prev is not null and t >= prev)::numeric
                          / nullif(count(*) filter (where prev is not null), 0), 0), 4)
    from o
  $q$, p_id, p_time, p_table::text, p_sample);
end;
$$;

create or replace function pgpm.status()
returns table (
  parent regclass, control_kind text, partition_step text, premake int, retention text,
  paused boolean, n_partitions bigint, default_rows bigint, default_oldest text, newest_bound text
)
language plpgsql as $$
declare r pgpm.config; v_nsp name; v_def text; v_drows bigint; v_old text; v_np bigint; v_new text;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;
    v_def := format('%I.%I', v_nsp, r.default_table);
    execute format('select count(*)::bigint, (select t.%I::text from %s t order by t.%I limit 1) from %s',
                   r.control_column, v_def, r.control_column, v_def) into v_drows, v_old;
    select count(*) into v_np from pgpm.part where parent_table = r.parent_table;
    execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass',
                   pgpm._native_type(r.control_kind), r.parent_table::text) into v_new;
    parent := r.parent_table; control_kind := r.control_kind; partition_step := r.partition_step;
    premake := r.premake; retention := r.retention; paused := r.paused; n_partitions := v_np;
    default_rows := v_drows; default_oldest := v_old; newest_bound := v_new;
    return next;
  end loop;
end;
$$;

-- restore_incoming_fks(): re-add the incoming FKs that adopt(..., p_incoming_fks => 'preserve')
-- recorded, pointing them back at the new partitioned parent (`NOT VALID` then `VALIDATE`, so the
-- re-add is online), but only once it is SAFE. Safe = the conversion is quiescent: the closed tail is
-- fully drained (no closed rows linger in the DEFAULT) and no in-flight, not-yet-attached child
-- partition exists. The drain moves rows out of the DEFAULT through such a child, during which a
-- referenced row is briefly outside the parent and a live NO ACTION FK would reject the move (see
-- DESIGN.md section 8), so the FK must stay dropped until the drain is idle. Returns the number
-- restored, 0 (a no-op) while the drain is still in flight, so `maintenance` can call it every tick
-- and it acts only when the table is ready.
create or replace function pgpm.restore_incoming_fks(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_closed bigint; v_inflight name;
  r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restorable and restored_at is null) then
    return 0;
  end if;
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- gate 1: the closed tail must be fully drained (open-interval rows in the DEFAULT are fine, they
  -- are still in the parent and the drain will not touch them).
  select closed_rows into v_closed from pgpm.check_default(p_parent);
  if coalesce(v_closed, 0) > 0 then return 0; end if;

  -- gate 2: no in-flight (un-attached) child partition mid-drain (same shape as adopt's orphan guard).
  select c.relname into v_inflight
    from pg_class c
   where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
     and c.relkind = 'r'
     and starts_with(c.relname, v_rel || '_p')
     and case when cfg.control_kind = 'id'
              then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
              else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$'
         end
     and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
   limit 1;
  if v_inflight is not null then return 0; end if;

  -- safe: re-add each preserved FK against the parent. The recorded definition already names the
  -- parent (it was captured before the rename, and that name is now the parent).
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restorable and restored_at is null order by id loop
    if (select relkind from pg_class where oid = r.referencing_table) = 'p' then
      -- The referencing side is itself partitioned (a self-referential FK is now on the parent).
      -- Postgres does not support NOT VALID foreign keys on a partitioned referencing table, so add
      -- it validating in one step. This single re-add is not online (it scans and takes a stronger
      -- lock), acceptable as a one-time conversion step; self-referential / partitioned-referencer
      -- FKs are typically on smaller hierarchy tables. The referential action and DEFERRABLE
      -- attributes ride along in the recorded definition either way.
      execute format('alter table %s add constraint %I %s',
                     r.referencing_table::text, r.constraint_name, r.definition);
    else
      execute format('alter table %s add constraint %I %s not valid',
                     r.referencing_table::text, r.constraint_name, r.definition);
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
    end if;
    -- keep the record, marked LIVE: maintenance may need to suspend (re-drop) it again before a
    -- later drain, so pgpm must remember which incoming FKs it manages even after restoring them.
    update pgpm.dropped_fk set restored_at = now() where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- suspend_incoming_fks(): the inverse of restore. When the closed tail has drain work pending, re-drop
-- any preserve-managed FK that is currently live, so the drain never moves a referenced row past a
-- live FK. That matters beyond a mere stall: a live ON DELETE CASCADE / SET NULL FK would silently
-- delete or null the referencing rows as the drain removes their referent from the DEFAULT (verified
-- on PG 17). maintenance calls this before each drain step; restore_incoming_fks re-adds once the
-- tail is drained, maintaining the invariant "a managed FK is live iff the closed tail is empty".
-- A no-op (returns 0) when the closed tail is empty, so it is safe to call every tick.
create or replace function pgpm.suspend_incoming_fks(p_parent regclass)
returns int language plpgsql as $$
declare v_closed bigint; r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restorable and restored_at is not null) then
    return 0;
  end if;
  select closed_rows into v_closed from pgpm.check_default(p_parent);
  if coalesce(v_closed, 0) = 0 then return 0; end if;   -- no drain work => leave live FKs in place
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restorable and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
    update pgpm.dropped_fk set restored_at = null where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'suspend_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- generate_fk_recovery(): per dropped incoming FK, emit a ready-to-review script
-- that rebuilds it against the partitioned parent. Targets the parent's actual PK:
-- reuses the existing local column for any PK column the old FK already referenced,
-- and adds a companion column only for the partition key it didn't. So id-by-id
-- partitioning degenerates to a trivial same-column re-point; time/uuid get a
-- composite FK with a backfilled companion. Generated, NOT executed.
create or replace function pgpm.generate_fk_recovery(p_parent regclass)
returns table (referencing_table regclass, sql text)
language plpgsql as $$
declare
  v_pkcols text[]; v_pktypes text[]; r pgpm.dropped_fk%rowtype;
  v_fk_cols text; v_ref_cols text; v_adds text; v_sets text; v_join text; v_companions text[];
  v_newcol text; pkc text; pos int; i int; sep text;
begin
  select array_agg(a.attname::text order by k.ord), array_agg(format_type(a.atttypid, a.atttypmod) order by k.ord)
    into v_pkcols, v_pktypes
    from pg_constraint c
    cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
   where c.conrelid = p_parent and c.contype = 'p';
  if v_pkcols is null then return; end if;

  -- 'restorable' rows are preserve-managed (re-added verbatim by restore_incoming_fks); only the
  -- 'drop'-mode rows need the composite-FK rebuild emitted here.
  for r in select * from pgpm.dropped_fk where parent_table = p_parent and not restorable order by id loop
    v_fk_cols := ''; v_ref_cols := ''; v_adds := ''; v_sets := ''; v_companions := array[]::text[]; sep := '';
    -- backfill join from the original FK mapping (parent cols = referencing cols)
    v_join := '';
    for i in 1 .. coalesce(array_length(r.referenced_columns, 1), 0) loop
      v_join := v_join || case when i > 1 then ' and ' else '' end
             || format('p.%I = r.%I', r.referenced_columns[i], r.referencing_columns[i]);
    end loop;

    for i in 1 .. array_length(v_pkcols, 1) loop
      pkc := v_pkcols[i];
      pos := array_position(r.referenced_columns, pkc);
      if pos is not null then
        v_fk_cols := v_fk_cols || sep || quote_ident(r.referencing_columns[pos]);
      else
        v_newcol := regexp_replace(r.referencing_columns[1], '_id$', '') || '_' || pkc;
        v_companions := v_companions || v_newcol;
        v_fk_cols := v_fk_cols || sep || quote_ident(v_newcol);
        v_adds := v_adds || format(E'ALTER TABLE %s ADD COLUMN %I %s;\n', r.referencing_table::text, v_newcol, v_pktypes[i]);
        v_sets := v_sets || case when v_sets <> '' then ', ' else '' end || format('%I = p.%I', v_newcol, pkc);
      end if;
      v_ref_cols := v_ref_cols || sep || quote_ident(pkc);
      sep := ', ';
    end loop;

    referencing_table := r.referencing_table;
    sql := format(E'-- Recover FK %I on %s ->%s %s.\n', r.constraint_name, r.referencing_table::text,
                  case when array_length(v_companions, 1) is null then ' (re-point)' else ' composite' end,
                  p_parent::text);
    sql := sql || v_adds;
    if v_sets <> '' then
      sql := sql || format(E'UPDATE %s r SET %s FROM %s p WHERE %s;\n', r.referencing_table::text, v_sets, p_parent::text, v_join);
    end if;
    for i in 1 .. coalesce(array_length(v_companions, 1), 0) loop
      sql := sql || format(E'ALTER TABLE %s ALTER COLUMN %I SET NOT NULL;\n', r.referencing_table::text, v_companions[i]);
    end loop;
    sql := sql || format(E'ALTER TABLE %s ADD CONSTRAINT %I\n  FOREIGN KEY (%s) REFERENCES %s (%s) NOT VALID;\n',
                  r.referencing_table::text, r.constraint_name, v_fk_cols, p_parent::text, v_ref_cols);
    sql := sql || format(E'ALTER TABLE %s VALIDATE CONSTRAINT %I;', r.referencing_table::text, r.constraint_name);
    if array_length(v_companions, 1) is not null then
      sql := sql || format(E'\n-- Then populate the new column(s) from the application: %s', array_to_string(v_companions, ', '));
    end if;
    return next;
  end loop;
end;
$$;

create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at from pgpm.part order by parent_table, lo;
