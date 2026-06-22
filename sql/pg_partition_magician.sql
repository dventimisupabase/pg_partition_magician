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
  drain_max_blocks int,
  -- adaptive closed-loop feathering (DESIGN.md section 8, mode 2). When on, maintenance senses
  -- checkpoint pressure each tick and rides the per-tick drain budget just under supply via AIMD
  -- (additive-increase when calm, halve on a forced checkpoint), instead of the fixed drain_batch.
  -- off = mode 1 (today's fixed gentle rate). drain_budget is the controller's current row budget
  -- (null until the first adaptive tick seeds it from drain_batch). The controller's signal is the WAL
  -- generation rate vs the sustainable rate (max_wal_size/checkpoint_timeout): drain_wal_lsn/drain_wal_at
  -- are the previous tick's WAL position + time (to compute the rate), drain_wal_high_water is the
  -- fraction of the sustainable rate at which to start backing off (leading), and drain_ckpt_seen is the
  -- last forced-checkpoint counter (a reactive backstop). All null = uninitialized (first tick is calm).
  drain_adaptive       boolean not null default false,
  drain_budget         int,
  drain_ckpt_seen      bigint,
  drain_wal_lsn        pg_lsn,
  drain_wal_at         timestamptz,
  drain_wal_high_water numeric not null default 1.0,
  -- ambient-contention signal (consumer priority): back off when non-pgpm client backends are stuck on
  -- IO/lock waits (the drain is starving the workload). Two complementary triggers, OR'd:
  --   * SELF-CALIBRATING (primary): a fixed waiter threshold is the wrong shape -- "normal" waiter count
  --     is box/workload-dependent (~0 idle, double digits busy). So we learn the recent normal as an EWMA
  --     (drain_ambient_baseline, smoothing drain_ambient_alpha) and back off on a RELATIVE surge: current
  --     waiters > drain_ambient_factor * baseline, floored at drain_ambient_floor so an idle box does not
  --     fire on a couple of transient waiters. drain_ambient_factor = 0 disables it (the default).
  --   * ABSOLUTE cap (optional backstop): back off when more than drain_ambient_max_waiters are contended,
  --     regardless of baseline. 0 = disabled. Useful as a hard ceiling on top of the relative trigger.
  -- 0/0 = ambient signal fully off (pure WAL behaviour). See DESIGN.md section 8.
  drain_ambient_max_waiters int     not null default 0,
  drain_ambient_factor      numeric not null default 0,
  drain_ambient_alpha       numeric not null default 0.2,
  drain_ambient_floor       int     not null default 2,
  drain_ambient_baseline    numeric
);
-- upgrade path for installs that predate these columns
alter table pgpm.config add column if not exists premake_retry_after timestamptz;
alter table pgpm.config add column if not exists drain_max_blocks int;
alter table pgpm.config add column if not exists drain_adaptive boolean not null default false;
alter table pgpm.config add column if not exists drain_budget int;
alter table pgpm.config add column if not exists drain_ckpt_seen bigint;
alter table pgpm.config add column if not exists drain_wal_lsn pg_lsn;
alter table pgpm.config add column if not exists drain_wal_at timestamptz;
alter table pgpm.config add column if not exists drain_wal_high_water numeric not null default 1.0;
alter table pgpm.config add column if not exists drain_ambient_max_waiters int not null default 0;
alter table pgpm.config add column if not exists drain_ambient_factor numeric not null default 0;
alter table pgpm.config add column if not exists drain_ambient_alpha numeric not null default 0.2;
alter table pgpm.config add column if not exists drain_ambient_floor int not null default 2;
alter table pgpm.config add column if not exists drain_ambient_baseline numeric;

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
  -- lifecycle marker for a preserve-managed incoming FK: null = currently DROPPED (awaiting restore),
  -- set = currently LIVE on the parent. maintenance keeps the invariant "a managed FK is live iff the
  -- closed tail is empty": it suspends (drops, restored_at -> null) before a drain that would move
  -- referenced rows, and restores (re-adds, restored_at -> now()) once the drain is idle. The row is
  -- kept after restore (rather than deleted) so the suspend/restore cycle can repeat.
  restored_at         timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate this column
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
  v_uchk_n bigint; v_uchk_frac numeric;
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

  -- Capture max(identity) to seed the parent's freshly-recreated identity sequence below: identity is
  -- moved from the default to the parent (whose sequence restarts at 1), so without this the next
  -- insert would collide. The PK is kept (never dropped), so the id index is intact and this is an
  -- index lookup, not a seq-scan, even on a large default.
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select coalesce(max(%I), 0)::bigint from %s', v_col, p_parent::text) into v_m;
      v_idmax := array_append(v_idmax, v_m);
    end loop;
  end if;

  -- pgpm NEVER rewrites the primary key (DESIGN.md sec 8). Postgres only requires a partitioned
  -- table's PK to INCLUDE the partition key (column order is irrelevant), so when the control column
  -- is already a member of the existing PK we reuse that PK verbatim -- the parent's PRIMARY KEY
  -- (step 8) reconciles the default's kept index in place, no drop, no O(rows) rebuild. If the table
  -- has a PK that does NOT include the control column (the classic id-PK table that wants time
  -- partitioning), we refuse with guidance rather than widen the key behind the operator's back. A
  -- table with no PK at all is fine (there is nothing to preserve).
  if v_oldpk is not null then
    if not (p_control::text = any(v_oldpk)) then
      raise exception 'pg_partition_magician: cannot partition % on % -- pgpm does not rewrite primary keys, and the primary key (%) does not include %. Make % part of the primary key first, then re-run adopt: the simplest modern data model is a single-column time-ordered key (bigint/Snowflake, UUIDv7, or ULID); to retrofit an existing key, widen the PK to include % via CREATE UNIQUE INDEX CONCURRENTLY on the new columns, then ALTER TABLE ... DROP CONSTRAINT <pk>, ADD PRIMARY KEY USING INDEX <idx>.',
        p_parent, p_control, array_to_string(v_oldpk, ', '), p_control, p_control, p_control;
    end if;
    v_pkcols := v_oldpk;   -- reuse the existing PK verbatim (it already includes the partition key)
  end if;

  -- secondary (non-PK, non-unique) indexes to recreate on the parent
  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid)) into v_idx_names, v_idx_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary and not i.indisunique;
  -- a unique secondary index (not the PK) can't be carried to a partitioned table unless it includes
  -- the partition key, and pgpm doesn't carry unique secondaries at all -- warn so the operator can
  -- recreate any it needs on the parent by hand.
  select count(*) into v_skipped from pg_index i
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary;
  if v_skipped > 0 then
    raise notice 'pg_partition_magician: skipped % unique secondary index(es) on %; recreate on the parent manually (must include the partition key)', v_skipped, p_parent;
  end if;

  -- 0. incoming FKs (capture before the rename; record after the new parent exists). pgpm never
  -- rewrites the PK, so the referenced unique key (the reused PK) always survives and an incoming FK
  -- can be re-pointed at the new parent verbatim once the drain is idle -- the 'preserve' lifecycle.
  -- We refuse by default (the operator opts into the drop-and-restore dance).
  if exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    if p_incoming_fks = 'error' then
      raise exception
        'pg_partition_magician: % has incoming foreign key(s) (%). Re-run with p_incoming_fks => ''preserve'' to keep them: pgpm drops each for the conversion and re-adds it against the new parent once the drain is idle.',
        p_parent,
        (select string_agg(conname || ' on ' || conrelid::regclass::text, ', ')
           from pg_constraint where confrelid = p_parent and contype = 'f');
    else   -- 'preserve'
      for v_fk in
        select c.conrelid::regclass as reltbl, c.conname, pg_get_constraintdef(c.oid) as def,
               (select array_agg(a.attname::text order by k.ord) from unnest(c.confkey) with ordinality as k(attnum, ord)
                  join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
          from pg_constraint c where c.confrelid = p_parent and c.contype = 'f'
      loop
        -- Preservable iff the parent keeps a unique key on EXACTLY this FK's referenced columns.
        -- Since the PK is reused verbatim, that means the FK must reference the primary key. The only
        -- way it can't is an FK referencing a non-PK unique key that cannot survive partitioning (a
        -- unique secondary not including the partition key) -- refuse with guidance.
        v_fk_eligible := v_pkcols is not null
          and (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            = (select array_agg(x order by x) from unnest(v_pkcols) x);
        if not v_fk_eligible then
          raise exception 'pg_partition_magician: cannot preserve incoming FK % on % -- it references (%), but the parent''s primary key is (%). An incoming FK must reference the primary key to be preserved.',
            v_fk.conname, v_fk.reltbl, array_to_string(v_fk.rcols, ', '), array_to_string(coalesce(v_pkcols, '{}'), ', ');
        end if;
        v_dropped := v_dropped || jsonb_build_object(
          'reltbl', v_fk.reltbl::text, 'conname', v_fk.conname::text, 'def', v_fk.def);
        execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
      end loop;
    end if;
  end if;

  -- 1. rename the live table to the DEFAULT partition name
  execute format('alter table %s rename to %I', p_parent::text, v_default);
  v_defreg := format('%I.%I', v_nsp, v_default)::regclass;

  -- 2. the existing PK is KEPT in place -- pgpm never drops or rebuilds it. The default carries its
  -- original PK index forward; step 8's parent PRIMARY KEY reconciles that index (metadata-only, no
  -- O(rows) build). (When the table had no PK there is nothing to keep, and the parent gets none.)

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

  -- record any dropped incoming FKs (the recorded definition already names the new parent); these are
  -- always preserve-managed now, re-added by restore_incoming_fks once the drain is idle.
  for v_e in select value from jsonb_array_elements(v_dropped) loop
    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
    values (v_parent, (v_e->>'reltbl')::regclass, v_e->>'conname', v_e->>'def');
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

-- One adopt, two type-safe overloads on the width parameter (DESIGN.md sec 8). The integer-grid and
-- time-grid families used to be three functions (adopt / adopt_by_id / adopt_by_uuidv7); they collapse
-- into a single `adopt` whose overload is chosen by the width type, with the kind read from the
-- control column. The old by_ names are removed (hard replace).
drop function if exists pgpm.adopt_by_id(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text);
drop function if exists pgpm.adopt_by_uuidv7(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text);
-- removed in the redesign (no PK rewrite -> no online PK build, no composite-FK recovery)
drop procedure if exists pgpm.build_pk_concurrently(regclass, name, interval, interval);
drop function if exists pgpm.generate_fk_recovery(regclass);

-- Time grid: interval width. The control column's type selects the kind -- a uuid column is uuidv7
-- (ULIDs stored as uuid included), anything else is time (timestamptz/timestamp/date; _adopt rejects
-- a non-time, non-uuid column). A bare interval literal is ambiguous against the bigint overload, so
-- callers cast: adopt(t, c, interval '1 month').
create or replace function pgpm.adopt(
  p_parent regclass, p_control name, p_interval interval,
  p_premake int default 4, p_retention interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass language sql as $$
  select pgpm._adopt(p_parent, p_control,
    case when (select t.typname from pg_attribute a join pg_type t on t.oid = a.atttypid
                 where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) = 'uuid'
         then 'uuidv7' else 'time' end,
    p_interval::text, p_anchor::text, p_premake,
    p_retention::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks);
$$;

-- Integer grid: bigint width. Covers int/bigint/numeric keys, including Snowflake-style ids.
create or replace function pgpm.adopt(
  p_parent regclass, p_control name, p_step bigint,
  p_premake int default 4, p_retention bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error'
) returns regclass language sql as $$
  select pgpm._adopt(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_premake,
                     p_retention::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks);
$$;

-- ============================== maintenance / observability ==============================

-- ===================== adaptive closed-loop feathering (DESIGN.md sec 8, mode 2) =====================

-- The LEADING congestion signal: the WAL generation rate vs the rate the checkpointer can sustain.
-- A forced checkpoint fires when WAL written since the last checkpoint reaches ~max_wal_size before
-- the checkpoint_timeout timer does; the I/O storm of that checkpoint flush is the latency tail the
-- bench saw at 40M. So the sustainable WAL rate is max_wal_size / checkpoint_timeout: generate WAL
-- faster than that and a forced checkpoint (and its storm) is coming. Sensing the RATE lets the drain
-- ease off BEFORE the checkpoint fires -- unlike the forced-checkpoint counter, which only moves once
-- the storm is already underway (that counter is kept below only as a reactive backstop). Reads
-- pg_current_wal_lsn() + settings, all available to a non-superuser (pg_control_checkpoint(), which
-- would give the exact distance-to-threshold, is superuser-gated on managed Postgres, so we use rate).
create or replace function pgpm._wal_sustainable_bps()
returns numeric language sql stable as $$
  select pg_size_bytes(current_setting('max_wal_size'))::numeric
         / greatest(1, extract(epoch from current_setting('checkpoint_timeout')::interval));
$$;

-- The decision (pure, unit-tested): are we over-driving the disk? True if the observed WAL rate exceeds
-- p_high_water of the sustainable rate (the LEADING trigger), OR a forced checkpoint already fired since
-- the last tick (the reactive backstop). Null observed rate (first tick) or unknown sustainable rate
-- (guard against divide-by-zero) => not congested.
create or replace function pgpm._feather_congested(
  p_observed_bps numeric, p_sustainable_bps numeric, p_high_water numeric, p_forced boolean
) returns boolean language sql immutable as $$
  select coalesce(p_forced, false)
      or (p_observed_bps is not null and coalesce(p_sustainable_bps, 0) > 0
          and p_observed_bps / p_sustainable_bps > p_high_water);
$$;

-- The AMBIENT signal: how many OTHER (non-pgpm) client backends are right now stuck on an IO, lock, or
-- buffer wait. This is the consumer-priority sensor the WAL rate misses entirely: when the drain crowds
-- the workload off the disk, those backends pile up on IO/Lock waits while generating little WAL of
-- their own (they are starved, not writing), so the WAL signal stays quiet. Counting the waiters sees
-- them directly. A point-in-time sample per maintenance tick -- noisy alone, smoothed by AIMD over
-- ticks. (Cross-role visibility of wait_event needs pg_monitor; backends of the maintenance role itself
-- are always visible. Excludes pgpm's own maintenance statements.)
create or replace function pgpm._ambient_io_waiters()
returns int language sql stable as $$
  select count(*)::int from pg_stat_activity
   where datname = current_database()
     and pid <> pg_backend_pid()
     and state = 'active'
     and backend_type = 'client backend'
     and wait_event_type in ('IO', 'Lock', 'LWLock', 'BufferPin')
     and coalesce(query, '') not like '%pgpm.%';
$$;

-- The ambient ABSOLUTE-cap decision (pure, unit-tested): congested if more than p_max waiters are
-- contended, regardless of the learned baseline. p_max = 0 disables this backstop. An optional hard
-- ceiling on top of the self-calibrating trigger below.
create or replace function pgpm._ambient_congested(p_waiters int, p_max int)
returns boolean language sql immutable as $$
  select coalesce(p_max, 0) > 0 and coalesce(p_waiters, 0) > p_max;
$$;

-- The SELF-CALIBRATING baseline (pure, unit-tested): one EWMA step toward the latest waiter sample.
-- This is the learned "normal" ambient waiter count, which the relative surge trigger compares against.
-- A null baseline (first observation) initialises to that observation; otherwise the standard
-- exponential moving average alpha*observed + (1-alpha)*baseline. The caller damps alpha during a surge
-- so a transient spike barely moves the baseline (clean detection), while a sustained regime shift is
-- still relearned over many ticks (the AIMD floor guarantees forward progress meanwhile).
create or replace function pgpm._ambient_baseline_next(p_baseline numeric, p_observed int, p_alpha numeric)
returns numeric language sql immutable as $$
  select case
           when p_baseline is null then p_observed::numeric
           else coalesce(p_alpha, 0) * p_observed + (1 - coalesce(p_alpha, 0)) * p_baseline
         end;
$$;

-- The SELF-CALIBRATING surge decision (pure, unit-tested): congested if the current waiter count exceeds
-- p_factor times the learned baseline. A fixed threshold is the wrong shape (normal is box-dependent), so
-- this is RELATIVE to what this server has been doing. p_floor is a minimum effective baseline so an idle
-- box (baseline ~0) does not fire on a couple of transient waiters. p_factor = 0 disables the signal.
create or replace function pgpm._ambient_surge(p_waiters int, p_baseline numeric, p_factor numeric, p_floor int)
returns boolean language sql immutable as $$
  select coalesce(p_factor, 0) > 0
     and p_waiters::numeric
         > greatest(coalesce(p_baseline, 0), coalesce(p_floor, 0)::numeric) * p_factor;
$$;

-- The reactive backstop sensor: the cluster's forced/requested-checkpoint counter. A *requested*
-- checkpoint means WAL hit max_wal_size (or an explicit CHECKPOINT). *Timed* checkpoints (the
-- checkpoint_timeout rhythm) are normal and deliberately NOT counted. The counter moved from
-- pg_stat_bgwriter to pg_stat_checkpointer in PG 17, so this is version-aware.
create or replace function pgpm._forced_checkpoints()
returns bigint language plpgsql stable as $$
declare v bigint;
begin
  if current_setting('server_version_num')::int >= 170000 then
    select num_requested into v from pg_stat_checkpointer;
  else
    select checkpoints_req into v from pg_stat_bgwriter;
  end if;
  return coalesce(v, 0);
end;
$$;

-- The controller: one AIMD step (the same additive-increase / multiplicative-decrease law TCP uses to
-- ride just under a link's capacity). Calm => probe the budget up by a small increment; congested =>
-- halve it. Clamped to [floor, ceiling] so it always makes forward progress and never over-probes.
-- Pure arithmetic, no side effects -- unit-tested directly.
create or replace function pgpm._aimd_next(
  p_current int, p_congested boolean, p_floor int, p_ceiling int, p_increment int
) returns int language sql immutable as $$
  select greatest(p_floor, least(p_ceiling,
    case when p_congested then floor(p_current / 2.0)::int
         else p_current + p_increment end));
$$;

-- Operator switch for mode 2. Off (default) keeps today's fixed gentle rate (drain_batch); on lets the
-- controller ride the budget under the WAL supply (leading signal above). Resets all controller state so
-- a toggle starts cleanly from drain_batch with no stale rate/checkpoint baseline.
create or replace function pgpm.set_drain_adaptive(p_parent regclass, p_enabled boolean default true)
returns void language plpgsql as $$
begin
  update pgpm.config
     set drain_adaptive = p_enabled, drain_budget = null, drain_ckpt_seen = null,
         drain_wal_lsn = null, drain_wal_at = null, drain_ambient_baseline = null
   where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- Operator switch for the self-calibrating ambient signal (DESIGN.md sec 8). p_factor > 0 turns it on:
-- the drain backs off when live waiters exceed p_factor times the learned baseline (relative surge),
-- p_alpha is the baseline's EWMA smoothing, p_floor the minimum effective baseline (idle-box guard).
-- p_factor = 0 turns it off. Resets the learned baseline so it re-learns cleanly from the next tick.
create or replace function pgpm.set_drain_ambient(
  p_parent regclass, p_factor numeric default 2.0, p_alpha numeric default 0.2, p_floor int default 2)
returns void language plpgsql as $$
begin
  update pgpm.config
     set drain_ambient_factor = p_factor, drain_ambient_alpha = p_alpha,
         drain_ambient_floor = p_floor, drain_ambient_baseline = null
   where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

create or replace function pgpm.maintenance(p_parent regclass)
returns text language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0; v_dropped int := 0; v_drain text := 'skipped'; v_restored int := 0; v_suspended int := 0;
  v_note text := '';
  v_batch int := null; v_ckpt bigint; v_congested boolean; v_budget int;
  v_now_lsn pg_lsn; v_now_ts timestamptz; v_secs numeric; v_obs_bps numeric;
  v_waiters int; v_wal_cong boolean; v_amb_cong boolean; v_reason text;
  v_amb_surge boolean; v_amb_abs boolean; v_amb_baseline numeric;
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

  -- Adaptive feathering (mode 2, DESIGN.md sec 8): ride the per-tick drain budget just under the WAL
  -- supply. Measure the WAL generation rate since the last tick and compare it to the sustainable rate
  -- (max_wal_size/checkpoint_timeout); if we are outrunning a fraction (drain_wal_high_water) of that, a
  -- forced checkpoint and its I/O storm are coming -- so back off NOW, before the storm (the LEADING
  -- signal). A forced checkpoint that slips through anyway is a reactive backstop. Then take one AIMD
  -- step and drain that many rows this tick instead of the fixed drain_batch.
  --   ceiling = drain_batch. CRITICAL: the budget never exceeds the operator's tuned rate. A bigger
  --     per-tick budget means a bigger single DELETE+INSERT, hence a bigger WAL spike per tick -- i.e.
  --     MORE checkpoint pressure, the very thing we are throttling. So adaptive only ever feathers DOWN
  --     from drain_batch; it can never drive harder than fixed mode, so it cannot worsen the tail.
  --     "Faster when there's slack" is delivered by the operator setting drain_batch to their optimistic
  --     slack rate -- adaptive then automatically backs off from it under pressure.
  --   floor = drain_batch/16: the gentlest sustained rate that still makes forward progress.
  --   recovery = drain_batch/8 per calm tick: a few ticks to climb back to the ceiling after a halve.
  -- Off => v_batch stays null => drain_step uses the fixed drain_batch exactly as before. drain_max_blocks
  -- (if set) still caps wide rows on top. Computed here; committed below only if the drain does work.
  if cfg.drain_adaptive then
    v_now_lsn := pg_current_wal_lsn();
    v_now_ts  := clock_timestamp();
    v_obs_bps := null;                                   -- first tick (no prior sample) => no rate yet
    if cfg.drain_wal_lsn is not null and cfg.drain_wal_at is not null then
      v_secs := extract(epoch from (v_now_ts - cfg.drain_wal_at));
      if v_secs > 0 then
        v_obs_bps := pg_wal_lsn_diff(v_now_lsn, cfg.drain_wal_lsn)::numeric / v_secs;
      end if;
    end if;
    v_ckpt      := pgpm._forced_checkpoints();
    -- Two complementary backoff signals, OR'd (see DESIGN sec 8): the WAL-rate signal (producer
    -- self-limit against checkpoint storms) and the ambient signal (consumer priority -- yield when
    -- non-pgpm backends are starved on IO/locks, which the WAL rate cannot see). Either fires => halve.
    v_wal_cong := pgpm._feather_congested(
                    v_obs_bps, pgpm._wal_sustainable_bps(), cfg.drain_wal_high_water,
                    cfg.drain_ckpt_seen is not null and v_ckpt > cfg.drain_ckpt_seen);
    -- The ambient signal: a SELF-CALIBRATING relative surge (current waiters vs the learned baseline)
    -- OR'd with the optional absolute cap. The baseline is an EWMA learned from the calm ticks; we damp
    -- its smoothing by 10x during a surge so a transient spike barely moves it (keeps the surge visible),
    -- while a sustained regime shift is still relearned over many ticks. Baseline only advances when the
    -- signal is enabled (drain_ambient_factor > 0); otherwise it stays null (pure WAL / absolute-cap mode).
    v_waiters  := pgpm._ambient_io_waiters();
    v_amb_surge := pgpm._ambient_surge(v_waiters, cfg.drain_ambient_baseline,
                                       cfg.drain_ambient_factor, cfg.drain_ambient_floor);
    v_amb_abs   := pgpm._ambient_congested(v_waiters, cfg.drain_ambient_max_waiters);
    v_amb_cong := v_amb_surge or v_amb_abs;
    v_amb_baseline := cfg.drain_ambient_baseline;
    if cfg.drain_ambient_factor > 0 then
      v_amb_baseline := pgpm._ambient_baseline_next(
        cfg.drain_ambient_baseline, v_waiters,
        case when v_amb_surge then cfg.drain_ambient_alpha / 10 else cfg.drain_ambient_alpha end);
    end if;
    v_congested := v_wal_cong or v_amb_cong;
    v_reason   := case when v_wal_cong and v_amb_cong then 'wal+ambient'
                       when v_wal_cong then 'wal' when v_amb_cong then 'ambient' else 'probe' end;
    v_budget    := pgpm._aimd_next(
                     coalesce(cfg.drain_budget, cfg.drain_batch),       -- start optimistic at the ceiling
                     v_congested,
                     greatest(1, cfg.drain_batch / 16),                 -- floor: minimum forward progress
                     cfg.drain_batch,                                   -- ceiling: never exceed the tuned rate
                     greatest(1, cfg.drain_batch / 8));                 -- additive recovery step
    v_batch := v_budget;
  end if;

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
    v_drain := pgpm.drain_step(p_parent, v_batch);
  exception when others then
    v_drain := 'deferred';
    v_note := v_note || ' drain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'drain_skip', left(sqlerrm, 200));
  end;

  -- Commit the adaptive step ONLY when the drain did work (moved rows or attached). A fully-drained,
  -- idle table must not churn config or log a budget row every tick (a standing steward ticks forever).
  -- Leaving the ckpt baseline stale across an idle gap just makes the next active tick treat any
  -- idle-period checkpoints as congestion and back off once -- the safe direction.
  if cfg.drain_adaptive and (v_drain like 'moved:%' or v_drain like 'attached:%') then
    update pgpm.config set drain_budget = v_budget, drain_ckpt_seen = v_ckpt,
                           drain_wal_lsn = v_now_lsn, drain_wal_at = v_now_ts,
                           drain_ambient_baseline = v_amb_baseline
      where parent_table = p_parent;
    v_note := v_note || format(' adaptive[%s %s]', v_budget, v_reason);
    insert into pgpm.log (parent_table, action, rows, method)
      values (p_parent, 'drain_budget', v_budget, v_reason);
  end if;

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
                  where parent_table = p_parent and restored_at is null) then
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
            where parent_table = p_parent and restored_at is null order by id loop
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
                  where parent_table = p_parent and restored_at is not null) then
    return 0;
  end if;
  select closed_rows into v_closed from pgpm.check_default(p_parent);
  if coalesce(v_closed, 0) = 0 then return 0; end if;   -- no drain work => leave live FKs in place
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
    update pgpm.dropped_fk set restored_at = null where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'suspend_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at from pgpm.part order by parent_table, lo;
