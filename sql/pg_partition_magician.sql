-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL range-partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling). No compiled
--     extension. Install with: psql -f this_file.sql.  Schema: pgpm.
--   * Manages the full lifecycle of native RANGE-partitioned tables: transmute an
--     existing (possibly huge, live) table online, obtain ahead of the write
--     frontier, drain the DEFAULT's closed tail, retain, all via maintenance.
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
  obtain          int         not null default 4,
  retain        text,                    -- interval (time/uuidv7) | bigint count (id); null = keep
  keep_default     boolean     not null default true,
  drain_batch      int         not null default 5000,
  default_table    name        not null,
  paused           boolean     not null default true,
  created_at       timestamptz not null default now(),
  -- when maintenance may next attempt obtain for this parent. Under sustained write contention
  -- obtain keeps losing the ACCESS EXCLUSIVE race, so on a deferral maintenance backs it off
  -- instead of retrying (and risking a wasted default scan) every tick. null = attempt now.
  obtain_retry_after timestamptz,
  -- optional block budget for the drain: cap each microbatch at ~this many heap+TOAST blocks
  -- (translated to a row limit via the default's average bytes/row), so wide rows can't make a
  -- single batch huge. null = cap by drain_batch rows only (default). See REDESIGN.md.
  drain_max_blocks int,
  -- adaptive closed-loop feathering (REDESIGN.md, mode 2). When on, maintenance senses
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
  -- ambient-contention signal (consumer priority): back off when the drain is crowding the live
  -- workload. Built only on catalogs a plain (non-superuser, non-pg_monitor) role can fully read, so
  -- pgpm's only runtime dependency stays pg_cron. Two role-independent terms feed the same
  -- self-calibrating controller, OR'd with an optional absolute cap:
  --   * LOCK-WAIT pressure (drain_ambient_baseline): how many non-pgpm backends are blocked on an
  --     ungranted lock (pg_locks, fully visible to any role -- unlike pg_stat_activity.wait_event, which
  --     pg_monitor masks for other roles). The drain's brief ATTACH (ACCESS EXCLUSIVE on the parent) and
  --     row/page locks show up here. SELF-CALIBRATING: a fixed threshold is the wrong shape ("normal" is
  --     box/workload-dependent), so learn the recent normal as an EWMA (smoothing drain_ambient_alpha)
  --     and back off on a RELATIVE surge: current > drain_ambient_factor * baseline, floored at
  --     drain_ambient_floor so an idle box does not fire on a couple of transient waiters.
  --     drain_ambient_factor = 0 disables BOTH self-calibrating terms (the default).
  --   * I/O LATENCY (drain_ambient_io_baseline): average ms per block read from disk, from
  --     pg_stat_database (blk_read_time / blks_read deltas; drain_io_read_time / drain_io_blks_read hold
  --     the previous cumulative sample). Captures the read-I/O starvation the lock signal misses.
  --     Self-calibrating the same way (EWMA baseline, surge at drain_ambient_factor * baseline). Inert
  --     when track_io_timing is off (no read time accrues, so the latency is 0 and never surges).
  --   * ABSOLUTE cap (optional backstop): back off when more than drain_ambient_max_waiters backends are
  --     lock-blocked, regardless of baseline. 0 = disabled.
  -- factor 0 + cap 0 = ambient signal fully off (pure WAL behaviour). See REDESIGN.md.
  drain_ambient_max_waiters int     not null default 0,
  drain_ambient_factor      numeric not null default 0,
  drain_ambient_alpha       numeric not null default 0.2,
  drain_ambient_floor       int     not null default 2,
  drain_ambient_baseline    numeric,        -- EWMA of the lock-wait count
  drain_ambient_io_baseline numeric,        -- EWMA of the I/O read latency (ms/block)
  drain_io_read_time        numeric,        -- previous cumulative pg_stat_database.blk_read_time
  drain_io_blks_read        bigint          -- previous cumulative pg_stat_database.blks_read
);
-- upgrade path for installs that predate these columns
alter table pgpm.config add column if not exists obtain_retry_after timestamptz;
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
alter table pgpm.config add column if not exists drain_ambient_io_baseline numeric;
alter table pgpm.config add column if not exists drain_io_read_time numeric;
alter table pgpm.config add column if not exists drain_io_blks_read bigint;
-- auto-refine (REDESIGN.md section 12): when set, maintenance feathers the oldest frozen coarse child
-- toward this target step, one budget-sized microbatch per tick. null = off (refine is operator-driven).
alter table pgpm.config add column if not exists refine_to text;
-- refine copy progress (REDESIGN.md section 10): the NATIVE-grid lo of the sub-range currently being
-- copied out of the coarse child under refinement -- a cross-tick high-water mark. refine COPIES (never
-- deletes), so the source never shrinks and cannot drive progress the way the drain's deletes do; this
-- cursor is the explicit progress state instead. null = no refine in flight; reset to null at the swap.
alter table pgpm.config add column if not exists refine_cursor text;

-- Registry of managed partitions (excludes the DEFAULT). lo/hi are NATIVE-grid
-- values as text (timestamptz for time/uuidv7, numeric for id).
create table if not exists pgpm.part (
  parent_table regclass    not null,
  child_name   name        not null,
  lo           text        not null,
  hi           text        not null,
  created_at   timestamptz not null default now(),
  -- false while the drain is still moving rows into this child (created standalone, not yet ATTACHed to
  -- the parent); flipped true at the attach. Lets an in-flight (or stalled, or interrupted) drain child
  -- be tracked in pgpm's catalog and surfaced by status(), instead of being discoverable only by
  -- scanning pg_class for the name pattern. obtain creates partitions already attached, so the default
  -- is true; only the drain inserts a row with attached=false. (issue #94)
  attached     boolean     not null default true,
  primary key (parent_table, child_name)
);
-- upgrade path for installs that predate this column
alter table pgpm.part add column if not exists attached boolean not null default true;

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
  -- lifecycle markers for a preserve-managed incoming FK (issue #95):
  --   restored_at null                     => DROPPED (RI off: during the drain, or initially after transmute).
  --   restored_at set, validated_at null   => RE-ADDED as NOT VALID: enforces RI for all NEW writes, but
  --                                            pre-existing rows are not yet verified (orphans, if any,
  --                                            are tolerated-but-flagged -- surfaced by status().fks_unvalidated
  --                                            and pgpm.incoming_fk_orphans(), cleared via validate_incoming_fks()).
  --   restored_at set, validated_at set    => fully VALIDATED.
  -- maintenance keeps "a managed FK is live (in any re-added form) iff the closed tail is empty": it
  -- suspends (re-drops, both timestamps -> null) before a drain that would move referenced rows, and
  -- restore_incoming_fks re-adds NOT VALID once the drain is idle. Splitting the re-add from the VALIDATE
  -- is what stops a pre-existing orphan from permanently bricking restoration: the FK comes back
  -- enforcing new writes immediately, and validation is a separate, loud step.
  restored_at         timestamptz,
  validated_at        timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate these columns
alter table pgpm.dropped_fk add column if not exists restored_at timestamptz;
alter table pgpm.dropped_fk add column if not exists validated_at timestamptz;
-- backfill validated_at for FKs already re-added by an older pgpm (which validated in one step): mark
-- them validated iff the actual constraint is currently convalidated. Keyed off pg_constraint, not a
-- blanket update, so a genuinely re-added-NOT-VALID FK (convalidated = false) is never wrongly marked.
update pgpm.dropped_fk d set validated_at = d.restored_at
 where d.restored_at is not null and d.validated_at is null
   and exists (select 1 from pg_constraint c
                where c.conrelid = d.referencing_table and c.conname = d.constraint_name
                  and c.contype = 'f' and c.convalidated);

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

-- _part_name maps a partition's NATIVE [lo, hi) to its child table name. A one-step range (hi is the
-- next grid value after lo, the common fine partition) keeps the historical name _p<lo>; a wider range
-- (a coarse / monolith child, REDESIGN.md section 6) is named _p<lo>_to_<hi> so it can never collide
-- with the fine child at its low edge. Both bounds are formatted at the step's granularity. hi is
-- optional: omitted (or equal to the one-step value) yields the fine name, so existing callers are
-- unchanged. The name is a human-facing LABEL only -- pgpm.part holds the authoritative bounds, so the
-- 63-byte identifier limit is cosmetic, never a correctness concern (a hash fallback is future work).
drop function if exists pgpm._part_name(name, text, text, text);
create or replace function pgpm._part_name(p_relname name, p_kind text, p_step text, p_lo_native text,
                                           p_hi_native text default null)
returns name language plpgsql immutable as $$
declare v_months int; v_secs double precision; fmt text; v_coarse boolean; v_lo text; v_hi text;
begin
  v_coarse := p_hi_native is not null
          and pgpm._native_gt(p_kind, p_hi_native, pgpm._grid_next(p_kind, p_step, p_lo_native));
  if p_kind in ('time', 'uuidv7') then
    v_months := (extract(year from p_step::interval) * 12 + extract(month from p_step::interval))::int;
    v_secs   := extract(epoch from p_step::interval);
    if    v_months >= 12 and v_months % 12 = 0 then fmt := 'YYYY';
    elsif v_months > 0                          then fmt := 'YYYY_MM';
    elsif v_secs  >= 86400                       then fmt := 'YYYY_MM_DD';
    elsif v_secs  >= 3600                        then fmt := 'YYYY_MM_DD_HH24';
    else                                              fmt := 'YYYY_MM_DD_HH24MI';
    end if;
    v_lo := to_char(p_lo_native::timestamptz, fmt);
    if v_coarse then
      v_hi := to_char(p_hi_native::timestamptz, fmt);
      return (p_relname || '_p' || v_lo || '_to_' || v_hi)::name;
    end if;
    return (p_relname || '_p' || v_lo)::name;
  else
    v_lo := lpad(floor(p_lo_native::numeric)::text, 19, '0');
    if v_coarse then
      v_hi := lpad(floor(p_hi_native::numeric)::text, 19, '0');
      return (p_relname || '_p' || v_lo || '_to_' || v_hi)::name;
    end if;
    return (p_relname || '_p' || v_lo)::name;
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
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'obtain', p_lo, p_hi, v_method);
end;
$$;

create or replace function pgpm.obtain(p_parent regclass)
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

  for k in 0 .. cfg.obtain loop
    if k > 0 then v_lo := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo); end if;
    v_hi   := pgpm._grid_next(cfg.control_kind, cfg.partition_step, v_lo);
    v_name := pgpm._part_name(v_rel, cfg.control_kind, cfg.partition_step, v_lo, v_hi);
    continue when to_regclass(format('%I.%I', v_nsp, v_name)) is not null;
    -- skip a candidate that overlaps an EXISTING attached partition (e.g. the coarse monolith that
    -- covers the active interval, REDESIGN.md section 7). Half-open [v_lo,v_hi) overlaps [p.lo,p.hi)
    -- iff p.hi > v_lo and v_hi > p.lo. Creating it would error on an overlapping partition; pgpm.part
    -- is the source of truth, and the non-overlap invariant holds over attached rows only.
    continue when exists (
      select 1 from pgpm.part p
       where p.parent_table = p_parent and p.attached
         and pgpm._native_gt(cfg.control_kind, p.hi, v_lo)
         and pgpm._native_gt(cfg.control_kind, v_hi, p.lo));
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
  v_retain_boundary text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_def   := format('%I.%I', v_nsp, cfg.default_table);
  v_batch := coalesce(p_batch, cfg.drain_batch, 5000);

  -- Block budget (REDESIGN.md): bound the microbatch by heap+TOAST blocks, not just rows, so a
  -- wide-row table (large jsonb/bytea) can't make one batch tens of GB. Translate the budget to a row
  -- cap via the default's average bytes/row and take the smaller of the two. When row stats exist that
  -- average is pg_table_size / reltuples. When they DON'T (a freshly transmuted / never-analyzed
  -- default -- exactly the early-drain window when the default is largest and widest), do NOT silently
  -- disable the budget (issue #93): estimate the average by sampling pg_column_size, which reads each
  -- toasted value's stored (post-compression) external size from its TOAST pointer WITHOUT fetching it,
  -- so the sample is cheap and TOAST-aware -- it scores a compressible column small (correctly, since
  -- it is cheap to move) and an incompressible wide one near its full width.
  if cfg.drain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_def::regclass;
    if coalesce(v_reltuples, 0) > 0 then
      v_avg := pg_table_size(v_def::regclass)::numeric / v_reltuples;   -- avg heap+TOAST bytes/row
    else
      execute format('select avg(pg_column_size(t))::numeric from (select * from %s limit 1000) t', v_def)
        into v_avg;
    end if;
    if coalesce(v_avg, 0) > 0 then
      v_blk_limit := greatest(1, floor(cfg.drain_max_blocks::numeric * 8192 / v_avg))::int;
      v_batch := least(v_batch, v_blk_limit);
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

  -- Retention-aware reclaim (issue #91): if this oldest closed interval is entirely below the
  -- retention horizon, retain() would DROP it the instant it became a partition -- so skip the
  -- materialize+attach and DELETE the batch straight out of the DEFAULT, paced exactly like a normal
  -- microbatch (and cheaper: no INSERT, no child, no attach). This reclaims the aged tail even when it
  -- never made it out of the DEFAULT, so retention bounds storage on a lagging drain too, and spares
  -- the wasted I/O of materializing a partition only to drop it next tick. The horizon matches
  -- retain()'s exactly: an interval is below it iff hi <= boundary (id: floor(frontier - retain);
  -- time/uuidv7: floor(now() - retain)).
  if cfg.retain is not null then
    if cfg.control_kind = 'id'
      then v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (v_frontier::numeric - cfg.retain::numeric)::text);
      else v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (now() - cfg.retain::interval)::text);
    end if;
    if not pgpm._native_gt(cfg.control_kind, v_hi, v_retain_boundary) then
      execute format($f$
        delete from %1$s where ctid in (select ctid from %1$s
                         where %2$I >= %3$L and %2$I < %4$L order by %2$I limit %5$s)
      $f$, v_def, cfg.control_column, v_lo_lit, v_hi_lit, v_batch);
      get diagnostics v_moved = row_count;
      insert into pgpm.log (parent_table, action, lo, hi, rows)
        values (p_parent, 'retain_reclaim', v_lo, v_hi, v_moved);
      execute format('select exists(select 1 from %s where %I >= %L and %I < %L)',
                     v_def, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit) into v_more;
      return case when v_more then 'reclaimed:' || v_moved else 'reclaimed:' || v_moved || ':done' end;
    end if;
  end if;

  if to_regclass(format('%I.%I', v_nsp, v_name)) is null then
    execute format('create table %I.%I (like %I.%I including defaults including storage including indexes including constraints excluding identity)',
                   v_nsp, v_name, v_nsp, v_rel);
    execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                   v_nsp, v_name, (v_name || '_ck'), cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
    -- record the child the moment it exists, marked in-flight (not yet attached) so it is tracked in
    -- pgpm's catalog across a multi-batch drain, not only at the final attach below (issue #94).
    insert into pgpm.part (parent_table, child_name, lo, hi, attached)
      values (p_parent, v_name, v_lo, v_hi, false) on conflict (parent_table, child_name) do nothing;
  end if;

  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped;

  -- ORDER BY the control column: the default's PK leads with the control column (transmute builds
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
  -- the interval is fully drained and the child is now attached: record it (or flip the in-flight row
  -- from the create step above to attached). Idempotent via the upsert.
  insert into pgpm.part (parent_table, child_name, lo, hi, attached) values (p_parent, v_name, v_lo, v_hi, true)
    on conflict (parent_table, child_name) do update set attached = true;
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

create or replace function pgpm.retain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_boundary text; v_frontier text; v_ncast text; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then return 0; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  if cfg.control_kind = 'id' then
    v_frontier := pgpm._frontier_native(p_parent);
    v_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   (v_frontier::numeric - cfg.retain::numeric)::text);
  else
    v_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                   (now() - cfg.retain::interval)::text);
  end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast)
  loop
    execute format('drop table %I.%I', v_nsp, r.child_name);
    delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi) values (p_parent, 'retain_drop', r.lo, r.hi);
    v_dropped := v_dropped + 1;
  end loop;
  return v_dropped;
end;
$$;

-- ============================== refine ==============================

-- refine splits a FROZEN coarse child (the monolith, or a coarser child from a prior pass) into finer
-- children, by COPYING the rows into standalone children in budget-sized microbatches, then in ONE atomic
-- step detaching the coarse source, attaching the fine children, and DROPping the source. It never deletes
-- a row out of the source -- the source stays whole and ATTACHED until the swap, so every row remains
-- visible through the parent the entire time. The product has no dead tuples (the fine children only ever
-- receive inserts) and no vacuum (the source's space is reclaimed by the DROP, not by DELETE). Because the
-- rows are never moved through an unattached child, refine NEVER opens the snapshot() read gap, and the
-- multi-tick COPY needs no FK leash (the drain's delete-and-move is the one that carries that) -- REDESIGN.md
-- sections 9 and 10. The one exception is the swap's DETACH itself: Postgres refuses to detach a partition
-- whose rows are still referenced by an incoming FK (the keys leave the parent between detach and the
-- re-attach of the copies, which it will not look past), so the swap transiently drops the incoming FK(s)
-- and re-adds them within its ONE atomic transaction -- invisible to other sessions, so RI is never visibly
-- off, unlike the move-model's whole-refine suspension. Retention-aware: a sub-range entirely below the
-- retention horizon is NOT copied (it is discarded with the source at the DROP), so retention costs no delete.
--
-- The work is a series of resumable microbatches (refine_step). Because the source is frozen and is never
-- deleted from, it cannot drive progress the way the drain's shrinking DEFAULT does, so progress is tracked
-- explicitly by config.refine_cursor: the native-grid lo of the sub-range currently being copied. A child is
-- built to completion (one budget batch at a time, resumed from its own high-water mark) before the cursor
-- advances to the next sub-range; when the cursor reaches the coarse hi every sub-range is copied (or aged
-- and skipped) and the swap runs. refine() loops refine_step in ONE transaction (atomic, gap-free) -- the
-- operator's "do it now". maintain() calls refine_step ONCE per tick when auto-refine is on (REDESIGN.md sec
-- 12), feathering the copy under the live workload across ticks. The cross-tick path leaves copies in
-- not-yet-attached children between ticks, but since the source still holds those rows, the parent's count
-- is never short and snapshot() must NOT union those copies (it would double-count).

-- one resumable microbatch of refine work on coarse child p_child toward target step p_target_step.
-- Returns: 'copied:N' (copied N rows into the current fine child), 'swapped:K' (cursor reached hi -> detached
-- the source, attached K fine children, dropped it: refine done), or a soft no-progress status ('active' =
-- not frozen yet, 'default_dirty' = a stray sits in the range, 'nosubdiv' = the step does not subdivide).
create or replace function pgpm.refine_step(
  p_parent regclass, p_child name, p_target_step text default null, p_batch int default null
) returns text language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_child regclass; v_cols text; v_ncast text; v_pkjoin text; v_keyidx oid;
  v_lo text; v_hi text; v_step text; v_frontier text; v_floor text; v_has boolean;
  v_retain_boundary text; v_batch int; v_reltuples real; v_avg numeric;
  v_cursor text; v_grid_lo text; v_sub_lo text; v_sub_hi text; v_sub_name name;
  v_lo_lit text; v_hi_lit text; v_moved bigint := 0; v_aged boolean; v_made int := 0; v_fk int := 0; r record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);
  v_step  := coalesce(p_target_step, cfg.partition_step);

  select lo, hi into v_lo, v_hi from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  if not found then
    raise exception 'pg_partition_magician: % is not an attached managed partition of %', p_child, p_parent;
  end if;
  v_child := format('%I.%I', v_nsp, p_child)::regclass;
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped;
  -- the reused-key equijoin (d.<key> = s.<key>, every key column): the copy is an anti-join against it, so
  -- a resumed batch never re-copies a row already in the child even when the control column is non-unique.
  -- The key is whatever transmute reused: a PRIMARY KEY, or (relaxed key contract) a UNIQUE constraint.
  -- A truly KEYLESS monolith has no key to identify rows by, so a resumable copy cannot dedup -- refine is
  -- refused for it below ('nokey'); the coarse monolith stays a correct, queryable permanent state.
  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is not null then
    select string_agg(format('d.%I = s.%I', a.attname, a.attname), ' and ' order by k.ord) into v_pkjoin
      from pg_index i
      cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indexrelid = v_keyidx;
  end if;
  if v_pkjoin is null then return 'nokey'; end if;

  -- frozen? (whole range at/below the current grid floor, so no live write still lands in it)
  v_frontier := pgpm._frontier_native(p_parent);
  v_floor    := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, v_frontier);
  if pgpm._native_gt(cfg.control_kind, v_hi, v_floor) then return 'active'; end if;
  -- the target step must actually subdivide the child
  if not pgpm._native_gt(cfg.control_kind, v_hi, pgpm._grid_next(cfg.control_kind, v_step, v_lo)) then
    return 'nosubdiv';
  end if;
  -- the DEFAULT must hold no rows inside the range (else a fine-child ATTACH at the swap would fail) --
  -- a stray there is the assistant drain's job first
  execute format('select exists (select 1 from %I.%I where %I >= %L and %I < %L)',
                 v_nsp, cfg.default_table, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo),
                 cfg.control_column, pgpm._encode(cfg.control_kind, v_hi)) into v_has;
  if v_has then return 'default_dirty'; end if;

  -- retention horizon (matches retain() and the drain's retain_reclaim, issue #91)
  if cfg.retain is not null then
    if cfg.control_kind = 'id'
      then v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (v_frontier::numeric - cfg.retain::numeric)::text);
      else v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (now() - cfg.retain::interval)::text);
    end if;
  end if;

  -- budget (rows per microbatch): drain_batch, capped by drain_max_blocks via the coarse child's stats
  v_batch := coalesce(p_batch, cfg.drain_batch, 5000);
  if cfg.drain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_child;
    if coalesce(v_reltuples, 0) > 0 then v_avg := pg_table_size(v_child)::numeric / v_reltuples;
    else execute format('select avg(pg_column_size(t))::numeric from (select * from %s limit 1000) t', v_child::text) into v_avg;
    end if;
    if coalesce(v_avg, 0) > 0 then
      v_batch := least(v_batch, greatest(1, floor(cfg.drain_max_blocks::numeric * 8192 / v_avg))::int);
    end if;
  end if;
  v_batch := greatest(1, v_batch);   -- a copied:0 batch must advance the cursor (0 < batch), never stall

  -- progress cursor: the lo of the sub-range currently being copied. null (fresh) or stale (out of this
  -- child's [lo,hi)) -> start at the coarse lo. The cursor only ever advances, one grid sub-range at a time.
  v_cursor := cfg.refine_cursor;
  if v_cursor is null
     or pgpm._native_gt(cfg.control_kind, v_lo, v_cursor)        -- cursor < coarse lo
     or pgpm._native_gt(cfg.control_kind, v_cursor, v_hi) then   -- cursor > coarse hi
    v_cursor := v_lo;
  end if;

  -- advance over any aged (below-horizon) sub-ranges without copying them: they would be dropped by retain()
  -- the instant they became partitions, so they are simply discarded with the source at the swap (never
  -- materialized, and never deleted out of the source either). Aged ranges are the lowest in control order, a
  -- contiguous prefix, so this loop only runs at the bottom of the child. One refine_skip per skipped range.
  loop
    exit when not pgpm._native_gt(cfg.control_kind, v_hi, v_cursor);   -- cursor >= hi: nothing left to copy
    v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_cursor);
    v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
    v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
    v_aged := v_retain_boundary is not null and not pgpm._native_gt(cfg.control_kind, v_sub_hi, v_retain_boundary);
    exit when not v_aged;                                             -- found a sub-range to copy
    insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'refine_aged', v_sub_lo, v_sub_hi, 0);
    v_cursor := v_sub_hi;                                             -- skip the aged sub-range (no copy, no delete)
  end loop;

  -- still a sub-range to copy: ensure its fine child exists (standalone, born with its validated bound
  -- CHECK), then COPY one budget batch into it. The copy is an anti-join against the child's PK, resumed from
  -- the child's current max(control), so it never re-copies and never deletes. row_count < batch means the
  -- remaining rows fit in this batch -> the sub-range is complete, advance the cursor to the next one.
  if pgpm._native_gt(cfg.control_kind, v_hi, v_cursor) then
    v_lo_lit := pgpm._encode(cfg.control_kind, v_sub_lo);
    v_hi_lit := pgpm._encode(cfg.control_kind, v_sub_hi);
    v_sub_name := pgpm._part_name(v_rel, cfg.control_kind, v_step, v_sub_lo, v_sub_hi);
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      execute format('create table %I.%I (like %I.%I including defaults including storage including indexes including constraints excluding identity)',
                     v_nsp, v_sub_name, v_nsp, v_rel);
      execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                     v_nsp, v_sub_name, (v_sub_name || '_ck'), cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit);
      insert into pgpm.part (parent_table, child_name, lo, hi, attached)
        values (p_parent, v_sub_name, v_sub_lo, v_sub_hi, false) on conflict (parent_table, child_name) do nothing;
    end if;
    execute format($f$
      insert into %7$I.%8$I (%6$s)
      select %6$s from %1$s s
       where s.%2$I >= coalesce((select max(d2.%2$I) from %7$I.%8$I d2), %3$L)
         and s.%2$I < %4$L
         and not exists (select 1 from %7$I.%8$I d where %9$s)
       order by s.%2$I
       limit %5$s
    $f$, v_child::text, cfg.control_column, v_lo_lit, v_hi_lit, v_batch, v_cols, v_nsp, v_sub_name, v_pkjoin);
    get diagnostics v_moved = row_count;
    if v_moved > 0 then
      insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'refine_copy', v_sub_lo, v_sub_hi, v_moved);
    end if;
    if v_moved < v_batch then v_cursor := v_sub_hi; end if;          -- sub-range fully copied: advance
    update pgpm.config set refine_cursor = v_cursor where parent_table = p_parent;
    return 'copied:' || v_moved;
  end if;

  -- cursor reached hi: every sub-range is copied (or aged and skipped). Swap atomically -- detach the source,
  -- attach every not-yet-attached fine child within its range (metadata-only via each child's validated
  -- CHECK), drop the source whole (no DELETE; the aged rows that were never copied go with it).
  --
  -- DETACH is refused while an incoming FK still references the source's rows (they leave the parent between
  -- detach and the re-attach of the copies). Drop the incoming FK(s) for the swap and re-add them, all inside
  -- THIS one transaction, so no other session ever observes RI off. force=true since the copy did not
  -- suspend; v_fk=0 means a drain already holds them suspended this tick (maintain re-adds them once the
  -- drain is idle, gated on no closed rows), so leave the re-add to that lifecycle rather than fight it.
  v_fk := pgpm.suspend_incoming_fks(p_parent, true);
  execute format('alter table %s detach partition %s', p_parent::text, v_child::text);
  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and not attached and lo::%s >= %L::%s and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast, v_ncast)
  loop
    execute format('alter table %s attach partition %I.%I for values from (%L) to (%L)',
                   p_parent::text, v_nsp, r.child_name,
                   pgpm._encode(cfg.control_kind, r.lo), pgpm._encode(cfg.control_kind, r.hi));
    execute format('alter table %I.%I drop constraint %I', v_nsp, r.child_name, (r.child_name || '_ck'));
    update pgpm.part set attached = true where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'refine_attach', r.lo, r.hi, 'check_skip');
    v_made := v_made + 1;
  end loop;
  delete from pgpm.part where parent_table = p_parent and child_name = p_child;
  execute format('drop table %s', v_child::text);
  -- re-add the FK(s) this swap dropped, against the new parent (the copies now hold every key). Only if WE
  -- dropped them (v_fk > 0): a v_fk = 0 means a drain already had them suspended, and re-adding mid-drain
  -- would break the drain's own leash -- maintain re-adds those once the drain is idle.
  if v_fk > 0 then perform pgpm.restore_incoming_fks(p_parent); end if;
  update pgpm.config set refine_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, rows, method) values (p_parent, 'refine', v_lo, v_hi, v_made, 'copy_swap_drop');
  return 'swapped:' || v_made;
end;
$$;

-- refine(): the synchronous "do it now" driver -- loops refine_step in ONE transaction (atomic, gap-free)
-- until the coarse child is fully split, and returns the number of fine children created. Soft no-progress
-- statuses become a hard error here (the operator gets a clear refusal); maintain() instead just skips.
create or replace function pgpm.refine(p_parent regclass, p_child name, p_target_step text default null)
returns int language plpgsql as $$
declare v_status text; v_iter int := 0;
begin
  loop
    v_status := pgpm.refine_step(p_parent, p_child, p_target_step, null);
    if v_status like 'swapped:%' then return split_part(v_status, ':', 2)::int; end if;
    if v_status in ('active', 'default_dirty', 'nosubdiv', 'nokey', 'idle') then
      raise exception 'pg_partition_magician: cannot refine % -- %', p_child,
        case v_status
          when 'active' then 'it is still active (not frozen); wait until the frontier passes its upper bound'
          when 'default_dirty' then 'the DEFAULT holds rows inside its range; drain them first'
          when 'nosubdiv' then 'the target step does not subdivide its range'
          when 'nokey' then 'it has no primary key or unique constraint, so a resumable copy cannot identify rows; refine is unavailable for keyless tables (the coarse monolith remains a valid, queryable state)'
          else 'nothing to refine' end;
    end if;
    v_iter := v_iter + 1;
    if v_iter > 10000000 then raise exception 'pg_partition_magician: refine safety limit'; end if;
  end loop;
end;
$$;

-- refine_history(): convenience -- refine the oldest coarse child (the monolith: the smallest-lo attached
-- partition) to p_target_step (default: the configured partition_step). Hierarchical refinement is just
-- repeated refine() calls with chosen steps.
create or replace function pgpm.refine_history(p_parent regclass, p_target_step text default null)
returns int language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_mon name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select child_name from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon;
  if v_mon is null then raise exception 'pg_partition_magician: % has no partitions to refine', p_parent; end if;
  return pgpm.refine(p_parent, v_mon, p_target_step);
end;
$$;

-- ============================== transmute ==============================

create or replace function pgpm._transmute(
  p_parent regclass, p_control name, p_control_kind text,
  p_step text, p_anchor text, p_obtain int, p_retain text,
  p_keep_default boolean, p_drain_batch int, p_paused boolean, p_incoming_fks text,
  p_drain_adaptive boolean, p_force_uuidv7 boolean default false
)
returns regclass language plpgsql as $$
declare
  v_nsp name; v_rel name; v_default name; v_defreg regclass; v_parent regclass;
  v_typname text; v_oldpk text[]; v_pkcols text[]; v_idcols name[]; v_pkname name; v_col name;
  v_idx_names text[]; v_idx_defs text[]; v_ctl_attnum int; v_uniq_bad text; v_old name; v_new name; v_pdef text; j int;
  v_add_pk boolean := false; v_add_uniq boolean := false; v_reuse_idx oid; v_reuse_conname name;
  v_uq_cols text[]; v_bare_uq text;
  v_fk record; v_dropped jsonb := '[]'::jsonb; v_e jsonb; v_fk_eligible boolean;
  v_uchk_n bigint; v_uchk_frac numeric;
  v_idmax bigint[]; v_m bigint; v_i int;
  v_monolith name; v_monreg regclass;
  v_frontier_native text; v_min_raw text; v_max_raw text; v_min_native text; v_lo_native text; v_hi_native text;
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

  -- Orphaned-child guard (REDESIGN.md): a drain creates each child partition as a standalone
  -- table (CREATE TABLE ... LIKE) and only ATTACHes it at the END of that child's drain. An
  -- interrupted drain therefore leaves an un-attached child -- which DROP TABLE <parent> CASCADE
  -- does NOT remove (an un-attached table has no dependency on the parent). If the table is later
  -- recreated/reloaded and re-transmuted, the next drain reuses the orphan by name and INSERTs rows
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
      raise exception 'pg_partition_magician: %.% already exists as a standalone table matching this parent''s partition naming -- most likely an orphan left by an interrupted drain. Drop it (drop table %.%) and retry transmute.',
        v_nsp, v_orphan, quote_ident(v_nsp), quote_ident(v_orphan);
    end if;
  end;

  -- uuidv7 sanity check (issue #96): a uuid control column is TREATED as uuidv7 on assumption, so we
  -- sample it. Genuine UUIDv7/ULID decodes to plausible recent timestamps (~1.0); random UUIDv4 scores
  -- ~0. Below a hard floor (0.5) the column is overwhelmingly random, so range-partitioning it would
  -- scatter rows across meaningless partitions on a garbage frontier -- so REFUSE, mirroring the
  -- float-key and PK refusals, unless the operator overrides with p_force_uuidv7. Between the floor and
  -- 0.95 we warn but proceed (mostly time-ordered with some noise, within the bounded-lag contract).
  if p_control_kind = 'uuidv7' then
    select sampled, fraction into v_uchk_n, v_uchk_frac from pgpm.check_uuidv7(p_parent, p_control, 1000);
    if coalesce(v_uchk_n, 0) > 0 then
      if v_uchk_frac < 0.5 and not p_force_uuidv7 then
        raise exception 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps -- the column looks random (UUIDv4), not time-ordered (UUIDv7/ULID), so range-partitioning it would scatter rows across meaningless partitions on a garbage frontier. If you are certain it is time-ordered, re-run with p_force_uuidv7 => true; otherwise partition on a genuinely time-ordered key. Inspect with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      elsif v_uchk_frac < 0.95 then
        raise notice 'pg_partition_magician: only % of % sampled % values decode to plausible recent timestamps; the column may be random (UUIDv4) rather than time-ordered (UUIDv7/ULID) -- partitioning may misbehave. Proceeding; verify with pgpm.check_uuidv7().',
          (round(v_uchk_frac * 100, 1) || '%'), v_uchk_n, quote_ident(p_control);
      end if;
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

  -- pgpm NEVER rewrites the key (REDESIGN.md): it REUSES an existing CONSTRAINT-backed unique key whose
  -- columns include the control column, so the parent (step 8) adopts the monolith's kept index in place,
  -- no drop, no O(rows) rebuild. Postgres only requires a partitioned table's PK/unique key to INCLUDE
  -- the partition key (column order is irrelevant). Preference: the PRIMARY KEY when it includes the
  -- control column (ADD PRIMARY KEY adopts the child PK index), else a UNIQUE CONSTRAINT that includes it
  -- (ADD UNIQUE adopts the child unique-constraint index). A *bare* unique index is deliberately NOT
  -- usable -- ADD UNIQUE would REBUILD it rather than adopt it -- so it is refused with the one metadata-
  -- only promotion the operator runs first. The reused key makes the control column NOT NULL (a PK
  -- guarantees it; for a unique constraint we require it, checked not scanned), so the per-column SET NOT
  -- NULL below stays a metadata no-op. Several shapes are refused up front (before the rename, table left
  -- untouched) rather than partitioned on a weak key.
  select a.attnum into v_ctl_attnum
    from pg_attribute a where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;

  if v_oldpk is not null and (p_control::text = any(v_oldpk)) then
    v_pkcols := v_oldpk;   -- reuse the existing PK verbatim (it already includes the partition key)
    v_add_pk := true;
  else
    -- no usable PK: look for a UNIQUE CONSTRAINT whose key includes the control column and is neither
    -- partial nor on an expression (the same shape pgpm can enforce on a partitioned table).
    select con.conname, con.conindid, array_agg(a.attname::text order by k.ord)
      into v_reuse_conname, v_reuse_idx, v_uq_cols
      from pg_constraint con
      join pg_index i on i.indexrelid = con.conindid
      cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
     where con.conrelid = p_parent and con.contype = 'u'
       and i.indpred is null and i.indexprs is null and v_ctl_attnum = any(con.conkey)
     group by con.conname, con.conindid
     order by con.conname limit 1;

    if v_reuse_conname is not null then
      if not (select a.attnotnull from pg_attribute a
                where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique constraint % includes the control column, but % is nullable and a partition key must be NOT NULL. Run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute.',
          p_parent, p_control, v_reuse_conname, p_control, p_parent::text, p_control;
      end if;
      v_pkcols := v_uq_cols;   -- reuse the unique constraint (drives FK eligibility and the parent ADD UNIQUE)
      v_add_uniq := true;
    else
      -- nothing reusable: give the operator a specific reason and the prep step that unblocks it.
      select c.relname into v_bare_uq
        from pg_index i join pg_class c on c.oid = i.indexrelid
       where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
         and i.indpred is null and i.indexprs is null
         and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])
         and not exists (select 1 from pg_constraint con where con.conindid = i.indexrelid)
       limit 1;
      if v_bare_uq is not null then
        raise exception 'pg_partition_magician: cannot transmute % on % -- the unique index % includes the control column but is a bare index, not a constraint, so pgpm cannot adopt it without an O(rows) rebuild. Promote it to a constraint first: ALTER TABLE % ADD CONSTRAINT %_key UNIQUE USING INDEX %; then re-run transmute. (pgpm reuses a primary key or a unique constraint, never a bare index, to keep the conversion metadata-only.)',
          p_parent, p_control, v_bare_uq, p_parent::text, v_bare_uq, v_bare_uq;
      elsif v_oldpk is not null then
        raise exception 'pg_partition_magician: cannot partition % on % -- pgpm does not rewrite keys, and the primary key (%) does not include %, nor does any unique constraint. Make % part of the primary key or add a unique constraint that includes it, then re-run transmute: the simplest modern data model is a single-column time-ordered key (bigint/Snowflake, UUIDv7, or ULID); to retrofit an existing key, widen it via CREATE UNIQUE INDEX CONCURRENTLY on the new columns, then ALTER TABLE ... DROP CONSTRAINT <pk>, ADD PRIMARY KEY USING INDEX <idx>.',
          p_parent, p_control, array_to_string(v_oldpk, ', '), p_control, p_control;
      else
        -- truly keyless: no key to reuse. pgpm still partitions it -- the parent gets no primary key or
        -- unique constraint, faithful to a keyless source (e.g. a plain hypertable un-hypertabled by
        -- from_hypertable). The one requirement is that the control column be NOT NULL: a partition key
        -- cannot be null, and pgpm never scans to enforce it, so a nullable control column is refused.
        -- (refine is unavailable for a keyless monolith -- it has no key to dedup a resumed copy -- but
        -- the coarse monolith is a correct, queryable permanent state; see refine_step.)
        if not (select a.attnotnull from pg_attribute a
                  where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) then
          raise exception 'pg_partition_magician: cannot transmute % on % -- the table has no primary key or unique constraint to reuse, and % is nullable. A partition key must be NOT NULL: run ALTER TABLE % ALTER COLUMN % SET NOT NULL first, then re-run transmute. (A primary key or unique constraint including % would also satisfy this.)',
            p_parent, p_control, p_control, p_parent::text, p_control, p_control;
        end if;
        -- proceed keyless: v_pkcols stays null, v_add_pk and v_add_uniq stay false.
      end if;
    end if;
  end if;

  -- Secondary indexes to carry onto the parent (step 9b recreates them as partitioned, attaching the
  -- default's). NON-unique secondaries always carry. A non-PK UNIQUE secondary can only become a
  -- partitioned unique index if its KEY columns include the partition key (Postgres's rule), so we carry
  -- those too -- global uniqueness genuinely preserved, exactly as the PK is reused when it covers the
  -- partition key -- and REFUSE the rest below, never silently dropping a uniqueness guarantee (issue
  -- #90). indkey casts via its text form (int2vector is 0-based; string_to_array gives a 1-based array),
  -- sliced to indnkeyatts so INCLUDE columns don't count; partial / expression unique indexes can't be
  -- carried either, so they fall to the refusal.
  -- (v_ctl_attnum was resolved with the key selection above). Exclude the reused unique-constraint index
  -- (v_reuse_idx): step 8 produces it via ADD UNIQUE, so it must not also be carried as a secondary.
  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid)) into v_idx_names, v_idx_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary
     and i.indexrelid <> coalesce(v_reuse_idx, 0::oid)
     and (not i.indisunique
          or (i.indpred is null and i.indexprs is null
              and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts])));
  -- Refuse any non-PK UNIQUE secondary that CANNOT be carried (its key omits the partition key, or it is
  -- partial / on an expression): global uniqueness cannot be enforced on the partitioned table, so this
  -- is the same refuse-with-guidance contract as the PK and incoming-FK cases, not a silent drop.
  select string_agg(c.relname, ', ' order by c.relname) into v_uniq_bad
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary
     and not (i.indpred is null and i.indexprs is null
              and v_ctl_attnum = any((string_to_array(i.indkey::text, ' ')::int2[])[1:i.indnkeyatts]));
  if v_uniq_bad is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the UNIQUE secondary index(es) (%) do not include the partition key % in their key columns (or are partial/expression indexes), so global uniqueness cannot be enforced on a partitioned table. Add % to the key of each, or drop them, then re-run transmute. A unique index that already includes % is carried automatically.',
      p_parent, v_uniq_bad, quote_ident(p_control), quote_ident(p_control), quote_ident(p_control);
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
        -- pgpm reuses the existing key verbatim (the PK, or a unique constraint when there is no usable
        -- PK), so the FK must reference that reused key -- both a PK and a unique constraint are valid FK
        -- targets. The only way it can't is an FK referencing a different unique key that cannot survive
        -- partitioning (one not including the partition key) -- refuse with guidance.
        v_fk_eligible := v_pkcols is not null
          and (select array_agg(x order by x) from unnest(v_fk.rcols) x)
            = (select array_agg(x order by x) from unnest(v_pkcols) x);
        if not v_fk_eligible then
          raise exception 'pg_partition_magician: cannot preserve incoming FK % on % -- it references (%), but the parent''s reused key is (%). An incoming FK must reference the reused primary key or unique constraint to be preserved.',
            v_fk.conname, v_fk.reltbl, array_to_string(v_fk.rcols, ', '), array_to_string(coalesce(v_pkcols, '{}'), ', ');
        end if;
        v_dropped := v_dropped || jsonb_build_object(
          'reltbl', v_fk.reltbl::text, 'conname', v_fk.conname::text, 'def', v_fk.def);
        execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
      end loop;
    end if;
  end if;

  -- ===== monolith cutover (REDESIGN.md sections 1, 2, 11) =====
  -- Bounds for the bounded coarse child the original table becomes: lo = grid_floor(min(control)),
  -- hi = B = the grid boundary just above the frontier. The monolith covers all history AND the
  -- current interval, so live writes keep landing in it until the frontier crosses B (then obtain's
  -- forward partitions take over and the monolith freezes). Every row satisfies [lo, B): lo <= min and
  -- B > frontier >= every row. An empty table anchors lo at the frontier's grid floor (empty monolith).
  -- frontier (now() for time, max(control) for id/uuidv7) and min(control), computed directly:
  -- pgpm.config does not exist yet, so _frontier_native (which reads config) cannot be used here.
  if p_control_kind = 'time' then
    v_frontier_native := now()::text;
  else
    execute format('select t.%I::text from %s t order by t.%I desc limit 1', p_control, p_parent::text, p_control)
      into v_max_raw;
    v_frontier_native := coalesce(pgpm._decode(p_control_kind, v_max_raw),
                                  case when p_control_kind = 'id' then p_anchor else now()::text end);
  end if;
  execute format('select t.%I::text from %s t order by t.%I asc limit 1', p_control, p_parent::text, p_control)
    into v_min_raw;
  v_min_native := coalesce(pgpm._decode(p_control_kind, v_min_raw),
                           pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native));
  v_lo_native  := pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_min_native);
  v_hi_native  := pgpm._grid_next(p_control_kind, p_step,
                    pgpm._grid_floor(p_control_kind, p_step, p_anchor, v_frontier_native));
  v_monolith   := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native);

  -- 0b. VALIDATE the monolith bound online (SHARE UPDATE EXCLUSIVE, no writer block), BEFORE the rename,
  -- so the ATTACH below is metadata-only and ACCESS EXCLUSIVE is never held across the scan. This is the
  -- one O(rows) read; the old model deferred it into a perpetual row-rewriting drain instead.
  execute format('alter table %s add constraint pgpm_monolith_bound check (%I >= %L and %I < %L) not valid',
                 p_parent::text, p_control, pgpm._encode(p_control_kind, v_lo_native),
                 p_control, pgpm._encode(p_control_kind, v_hi_native));
  execute format('alter table %s validate constraint pgpm_monolith_bound', p_parent::text);

  -- 1. rename the live table to the MONOLITH (coarse child) name
  execute format('alter table %s rename to %I', p_parent::text, v_monolith);
  v_monreg := format('%I.%I', v_nsp, v_monolith)::regclass;

  -- 2. the existing PK is KEPT in place; step 8 reconciles the monolith's promoted index (metadata-only).

  -- 3. drop identity on the monolith; key columns NOT NULL (metadata no-ops: PK => NOT NULL)
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I drop identity if exists', v_monreg::text, v_col);
    end loop;
  end if;
  execute format('alter table %s alter column %I set not null', v_monreg::text, p_control);
  -- only a reused PRIMARY KEY makes its other columns NOT NULL; a reused UNIQUE constraint legitimately
  -- permits nullable non-control columns, so leave those as they are (and never scan them).
  if v_add_pk and v_pkcols is not null then
    foreach v_col in array v_pkcols loop
      execute format('alter table %s alter column %I set not null', v_monreg::text, v_col);
    end loop;
  end if;

  -- 5. create the partitioned parent under the original name (no PK yet)
  execute format('create table %I.%I (like %s including defaults including generated including storage) partition by range (%I)',
                 v_nsp, v_rel, v_monreg::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_rel)::regclass;

  -- 6. re-establish identity on the parent
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I add generated by default as identity', v_parent::text, v_col);
    end loop;
  end if;

  -- 7. attach the original as the bounded MONOLITH child (metadata-only via the validated CHECK), then
  -- drop the now-redundant CHECK (the partition bound enforces it).
  execute format('alter table %s attach partition %s for values from (%L) to (%L)',
                 v_parent::text, v_monreg::text,
                 pgpm._encode(p_control_kind, v_lo_native), pgpm._encode(p_control_kind, v_hi_native));
  execute format('alter table %s drop constraint pgpm_monolith_bound', v_monreg::text);

  -- 8. parent key -- adopts the monolith's kept constraint index (metadata-only, no rebuild): a PRIMARY
  -- KEY when the reused key was the PK, a UNIQUE constraint when it was a unique constraint.
  if v_add_pk then
    execute format('alter table %s add primary key (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  elsif v_add_uniq then
    execute format('alter table %s add unique (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  end if;

  -- 8b. advance each identity sequence past the largest existing value (captured up front: index lookup).
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_parent::text, v_idcols[v_i], v_idmax[v_i] + 1);
    end loop;
  end if;

  -- 9b. recreate secondary indexes as partitioned indexes, attaching the monolith's
  if v_idx_names is not null then
    for j in 1 .. array_length(v_idx_names, 1) loop
      v_old  := v_idx_names[j]::name;
      v_new  := (v_old || '_pgpm')::name;
      v_pdef := regexp_replace(v_idx_defs[j], '^CREATE (UNIQUE )?INDEX \S+ ON ',
                               'CREATE \1INDEX ' || quote_ident(v_new) || ' ON ONLY ');
      execute v_pdef;
      execute format('alter index %I.%I attach partition %I.%I', v_nsp, v_new, v_nsp, v_old);
    end loop;
  end if;

  -- 9c. create a fresh EMPTY default LAST as the leading-edge safety net (REDESIGN.md section 3). Created
  -- after the parent's PK and secondary indexes exist, it auto-inherits matching (empty) indexes. Kept
  -- empty, it keeps obtain on its cheap plain path; the janitor drain evacuates any stray that lands here.
  execute format('create table %I.%I partition of %I.%I default', v_nsp, v_default, v_nsp, v_rel);
  v_defreg := format('%I.%I', v_nsp, v_default)::regclass;

  -- 10. register
  insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                           obtain, retain, keep_default, drain_batch, default_table, paused, drain_adaptive)
  values (v_parent, p_control, p_control_kind, p_step, p_anchor, p_obtain, p_retain,
          p_keep_default, p_drain_batch, v_default, p_paused, p_drain_adaptive)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, control_kind = excluded.control_kind,
    partition_step = excluded.partition_step, partition_anchor = excluded.partition_anchor,
    obtain = excluded.obtain, retain = excluded.retain, keep_default = excluded.keep_default,
    drain_batch = excluded.drain_batch, default_table = excluded.default_table, paused = excluded.paused,
    drain_adaptive = excluded.drain_adaptive;

  insert into pgpm.log (parent_table, action) values (v_parent, 'transmute');

  -- record the original table, now the bounded MONOLITH coarse child, as an attached partition
  -- (REDESIGN.md section 7) so obtain's overlap check and status() see it.
  insert into pgpm.part (parent_table, child_name, lo, hi, attached)
    values (v_parent, v_monolith, v_lo_native, v_hi_native, true);

  -- record any dropped incoming FKs (the recorded definition already names the new parent); these are
  -- always preserve-managed now, re-added by restore_incoming_fks once the drain is idle.
  for v_e in select value from jsonb_array_elements(v_dropped) loop
    insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
    values (v_parent, (v_e->>'reltbl')::regclass, v_e->>'conname', v_e->>'def');
    insert into pgpm.log (parent_table, action, method) values (v_parent, 'drop_incoming_fk', v_e->>'conname');
  end loop;

  -- NOTE: obtain is intentionally NOT run inside transmute. The cutover above is the online work (one
  -- SHARE UPDATE EXCLUSIVE validate scan, then a brief metadata-only ACCESS EXCLUSIVE rename and attach).
  -- Run pgpm.obtain(parent) (or pgpm.maintain, or the scheduled job) AFTER transmute to build the forward
  -- partitions; with an EMPTY default, obtain takes the cheap plain path (no scan). Until the frontier
  -- crosses B, live writes land in the monolith (the current interval lives there too).
  return v_parent;
end;
$$;

-- One transmute, two type-safe overloads on the width parameter (REDESIGN.md). The integer-grid and
-- time-grid families used to be three functions (transmute / transmute_by_id / transmute_by_uuidv7); they collapse
-- into a single `transmute` whose overload is chosen by the width type, with the kind read from the
-- control column. The old by_ names are removed (hard replace).
drop function if exists pgpm.transmute_by_id(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text);
drop function if exists pgpm.transmute_by_uuidv7(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text);
-- removed in the redesign (no PK rewrite -> no online PK build, no composite-FK recovery)
drop procedure if exists pgpm.build_pk_concurrently(regclass, name, interval, interval);
drop function if exists pgpm.generate_fk_recovery(regclass);

-- Time grid: interval width. The control column's type selects the kind -- a uuid column is TREATED as
-- uuidv7 (ULIDs stored as uuid included; PostgreSQL has no UUIDv7 type to detect, so this is an
-- assumption check_uuidv7 samples to gate, not a verification: a column that samples as overwhelmingly
-- random (UUIDv4) is refused unless p_force_uuidv7 => true), anything else is time
-- (timestamptz/timestamp/date; _transmute rejects a non-time, non-uuid column). A bare interval literal is ambiguous against the bigint overload, so
-- callers cast: transmute(t, c, interval '1 month').
create or replace function pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 4, p_retain interval default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_drain_adaptive boolean default false, p_force_uuidv7 boolean default false
) returns regclass language sql as $$
  select pgpm._transmute(p_parent, p_control,
    case when (select t.typname from pg_attribute a join pg_type t on t.oid = a.atttypid
                 where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped) = 'uuid'
         then 'uuidv7' else 'time' end,
    p_interval::text, p_anchor::text, p_obtain,
    p_retain::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks, p_drain_adaptive, p_force_uuidv7);
$$;

-- Integer grid: bigint width. Covers int/bigint/numeric keys, including Snowflake-style ids.
create or replace function pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 4, p_retain bigint default null, p_keep_default boolean default true,
  p_drain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_drain_adaptive boolean default false
) returns regclass language sql as $$
  select pgpm._transmute(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_obtain,
                     p_retain::text, p_keep_default, p_drain_batch, p_paused, p_incoming_fks, p_drain_adaptive);
$$;

-- Reverse a transmute, exactly while it is still reversible. transmute's cutover moves no data and
-- creates no real partitions (obtain does that, later -- see the NOTE in _transmute), so until
-- maintenance/obtain has run the DEFAULT partition still holds 100% of the rows and the original
-- table is sitting there untouched, merely renamed and attached. untransmute exploits that: detach the
-- DEFAULT (it is a complete standalone table again the instant it detaches, because transmute never
-- drops its PK), drop the now-childless parent, rename the DEFAULT back, and undo the few things
-- transmute changed on it (identity moved to the parent, the drain's autovacuum knobs, preserved
-- incoming FKs). It is a one-way door the moment a real partition exists: once obtain has run, live
-- writes route into real partitions (and the drain may have moved rows out of the DEFAULT), so the
-- DEFAULT is no longer the whole table -- untransmute then refuses. Returns the restored table.
--
-- Fidelity notes: an identity column comes back GENERATED BY DEFAULT (transmute already normalises
-- ALWAYS -> BY DEFAULT on the way in, so a round trip is stable), and the control column is left NOT
-- NULL (transmute set it; a nullable partition key is a foot-gun, and we do not record prior
-- nullability). Everything else -- rows, PK, secondary indexes, their names -- is byte-for-byte.
create or replace function pgpm.untransmute(p_parent regclass)
returns regclass language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_monreg regclass; v_restored regclass;
  v_mon name; v_mon_lo text; v_mon_hi text; v_ncast text; v_outside boolean;
  v_idcols name[]; v_idmax bigint[]; v_col name; v_m bigint; v_i int;
  r pgpm.dropped_fk%rowtype;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed by pgpm (nothing to untransmute)', p_parent;
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- THE GATE (REDESIGN.md section 13): a clean (metadata-only) reverse needs the original table still
  -- intact as the MONOLITH, holding the whole table, with nothing landed outside it. The monolith is the
  -- attached partition with the smallest lo (it starts at grid_floor(min(control)), strictly below B,
  -- while every forward partition starts at B or higher). The reverse is a one-way door once any row
  -- lives outside the monolith's [lo, hi): a forward partition after the frontier crosses B, a backdated
  -- stray in the DEFAULT, or finer children from a refinement (Tier 2 foldback / Tier 3 merge not built).
  execute format('select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon, v_mon_lo, v_mon_hi;
  if v_mon is null then
    raise exception 'pg_partition_magician: cannot untransmute % -- no managed partition found', p_parent;
  end if;
  v_monreg := format('%I.%I', v_nsp, v_mon)::regclass;
  execute format('select exists (select 1 from %s where %I >= %L or %I < %L)',
                 p_parent::text, cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_hi),
                 cfg.control_column, pgpm._encode(cfg.control_kind, v_mon_lo)) into v_outside;
  if v_outside then
    raise exception 'pg_partition_magician: cannot untransmute % -- rows now live outside the original monolith (a forward partition past B, a backdated stray, or a refinement has split it), so a metadata-only reverse would lose data. This is a one-way door once the frontier crosses B or refinement begins.',
      p_parent;
  end if;

  -- capture the identity columns and their current max BEFORE dropping anything (transmute moved
  -- identity from the table to the parent; dropping the parent loses it, so we re-establish it on the
  -- restored monolith). The max is an index lookup (the PK is intact), not a seq-scan.
  select array_agg(a.attname order by a.attnum) into v_idcols
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a', 'd') and not a.attisdropped;
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select coalesce(max(%I), 0)::bigint from %s', v_col, p_parent::text) into v_m;
      v_idmax := array_append(v_idmax, v_m);
    end loop;
  end if;

  -- preserved incoming FKs: drop any currently LIVE on the parent so the parent can be dropped (an
  -- incoming FK is a constraint on the referencing table pointing AT the parent). All recorded FKs are
  -- re-added against the restored table at the end.
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
  end loop;

  -- detach the MONOLITH (the original table, holding everything; PK + secondary indexes intact), then
  -- drop the childless parent -- which cascades the empty DEFAULT and any empty forward partitions, and
  -- takes the parent PK, the partitioned _pgpm indexes, and the parent's identity sequence with it.
  -- DETACH FIRST: dropping a partitioned parent cascades to its partitions, which would destroy the data.
  execute format('alter table %s detach partition %s', p_parent::text, v_monreg::text);
  execute format('drop table %s', p_parent::text);

  -- re-establish identity on the restored monolith and reseed past the captured max (mirrors transmute's
  -- step 6/8b, applied back to the table); without the reseed the next insert would collide at 1.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('alter table %s alter column %I add generated by default as identity',
                     v_monreg::text, v_idcols[v_i]);
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_monreg::text, v_idcols[v_i], v_idmax[v_i] + 1);
    end loop;
  end if;

  -- rename the monolith back to the original table name. (transmute never renamed the kept PK or
  -- secondary indexes, so those names are already the originals.)
  execute format('alter table %s rename to %I', v_monreg::text, v_rel);
  v_restored := format('%I.%I', v_nsp, v_rel)::regclass;

  -- re-add every preserved incoming FK against the restored table. The recorded definition names the
  -- parent, whose name the restored table now carries again. Mirror restore_incoming_fks: a
  -- partitioned referencer validates in one step (no NOT VALID), anything else NOT VALID + VALIDATE.
  for r in select * from pgpm.dropped_fk where parent_table = p_parent order by id loop
    if (select relkind from pg_class where oid = r.referencing_table) = 'p' then
      execute format('alter table %s add constraint %I %s',
                     r.referencing_table::text, r.constraint_name, r.definition);
    else
      execute format('alter table %s add constraint %I %s not valid',
                     r.referencing_table::text, r.constraint_name, r.definition);
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
    end if;
  end loop;

  -- forget all pgpm state for this table (matched by the dropped parent's oid, which p_parent still
  -- carries), and log the reversal against the restored table.
  delete from pgpm.dropped_fk where parent_table = p_parent;
  delete from pgpm.part where parent_table = p_parent;
  delete from pgpm.config where parent_table = p_parent;
  insert into pgpm.log (parent_table, action) values (v_restored, 'untransmute');

  return v_restored;
end;
$$;

-- ============================== maintenance / observability ==============================

-- ===================== adaptive closed-loop feathering (REDESIGN.md, mode 2) =====================

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

-- The AMBIENT signal, term 1: how many OTHER (non-pgpm) backends are right now blocked on an ungranted
-- lock. This is a consumer-priority sensor the WAL rate misses entirely -- when the drain's brief ATTACH
-- (ACCESS EXCLUSIVE on the parent) or its row/page locks block the workload, those backends queue here
-- while generating little WAL of their own. Read from pg_locks, which is FULLY VISIBLE to any role (no
-- pg_monitor needed, unlike pg_stat_activity.wait_event, which is masked for other roles); this is what
-- lets pgpm keep pg_cron as its only runtime dependency. count(distinct pid) so one blocked backend
-- counts once however many lock rows it waits on; excludes pgpm's own maintenance backend. A
-- point-in-time sample per tick -- noisy alone, smoothed by the EWMA baseline and AIMD over ticks.
create or replace function pgpm._ambient_lock_waiters()
returns int language sql stable as $$
  select count(distinct pid)::int from pg_locks
   where not granted and pid is not null and pid <> pg_backend_pid();
$$;

-- The AMBIENT signal, term 2 (pure): average ms per block read from disk over the interval between two
-- cumulative pg_stat_database samples (blk_read_time / blks_read). This is the read-I/O-starvation
-- sensor the lock signal misses: when the drain saturates the disk, the workload's reads slow down and
-- this latency climbs. Returns NULL when there is no prior sample or no blocks were read this interval
-- (nothing to measure). When track_io_timing is OFF, blk_read_time never advances, so the delta is 0
-- and this returns 0 -- inert, never surges. Like blk timing generally, this needs no elevated role.
create or replace function pgpm._ambient_io_latency(
  p_prev_time numeric, p_prev_blks bigint, p_cur_time numeric, p_cur_blks bigint)
returns numeric language sql immutable as $$
  select case
           when p_prev_time is null or p_prev_blks is null then null
           when coalesce(p_cur_blks, 0) - p_prev_blks <= 0 then null      -- no disk reads this interval
           when coalesce(p_cur_time, 0) - p_prev_time < 0 then null       -- counter reset
           else (p_cur_time - p_prev_time) / (p_cur_blks - p_prev_blks)   -- ms per block read
         end;
$$;

-- The ambient I/O-latency surge decision (pure, unit-tested): congested when the read latency exceeds
-- p_factor times the learned baseline, floored at p_floor (ms/block) so an idle/fast box (baseline ~0)
-- does not fire on a tiny absolute latency. Mirrors _ambient_surge but on a numeric latency rather than
-- an integer count. p_factor = 0 (the shared ambient factor) disables it; a NULL latency is calm.
create or replace function pgpm._ambient_io_surge(
  p_latency numeric, p_baseline numeric, p_factor numeric, p_floor numeric)
returns boolean language sql immutable as $$
  select coalesce(p_factor, 0) > 0 and p_latency is not null
     and p_latency > greatest(coalesce(p_baseline, 0), coalesce(p_floor, 0)) * p_factor;
$$;

-- The ambient ABSOLUTE-cap decision (pure, unit-tested): congested if more than p_max waiters are
-- contended, regardless of the learned baseline. p_max = 0 disables this backstop. An optional hard
-- ceiling on top of the self-calibrating trigger below.
create or replace function pgpm._ambient_congested(p_waiters int, p_max int)
returns boolean language sql immutable as $$
  select coalesce(p_max, 0) > 0 and coalesce(p_waiters, 0) > p_max;
$$;

-- The SELF-CALIBRATING baseline (pure, unit-tested): one EWMA step toward the latest sample. This is
-- the learned "normal" the relative surge triggers compare against; it serves BOTH ambient terms (the
-- lock-wait count and the I/O latency), so p_observed is numeric (a count auto-casts). A null baseline
-- (first observation) initialises to that observation; otherwise the standard exponential moving average
-- alpha*observed + (1-alpha)*baseline. The caller damps alpha during a surge so a transient spike barely
-- moves the baseline (clean detection), while a sustained regime shift is still relearned over many
-- ticks (the AIMD floor guarantees forward progress meanwhile).
drop function if exists pgpm._ambient_baseline_next(numeric, integer, numeric);
create or replace function pgpm._ambient_baseline_next(p_baseline numeric, p_observed numeric, p_alpha numeric)
returns numeric language sql immutable as $$
  select case
           when p_baseline is null then p_observed
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

-- Operator switch for the self-calibrating ambient signal (REDESIGN.md). p_factor > 0 turns it on:
-- the drain backs off when live waiters exceed p_factor times the learned baseline (relative surge),
-- p_alpha is the baseline's EWMA smoothing, p_floor the minimum effective baseline (idle-box guard).
-- p_factor = 0 turns it off. Resets the learned baseline so it re-learns cleanly from the next tick.
create or replace function pgpm.set_drain_ambient(
  p_parent regclass, p_factor numeric default 2.0, p_alpha numeric default 0.2, p_floor int default 2)
returns void language plpgsql as $$
begin
  update pgpm.config
     set drain_ambient_factor = p_factor, drain_ambient_alpha = p_alpha,
         drain_ambient_floor = p_floor, drain_ambient_baseline = null,
         drain_ambient_io_baseline = null
   where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- Operator switch for auto-refine (REDESIGN.md sec 12). p_target_step (an interval for time/uuidv7, a
-- bigint step as text for id) turns it on: each maintenance tick feathers the oldest frozen coarse child
-- one budget-sized microbatch toward that granularity. null turns it off (refine stays operator-driven via
-- refine()/refine_history()). This only PACES refinement across ticks; refine_step enforces its own
-- preconditions (frozen, default-clear), so enabling it is always safe.
create or replace function pgpm.set_refine(p_parent regclass, p_target_step text default null)
returns void language plpgsql as $$
begin
  update pgpm.config set refine_to = p_target_step where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- pause/resume the scheduled lifecycle for one table. transmute registers a table paused by default
-- (the deliberate two-step: convert, inspect, then go live), and maintenance is a no-op while paused.
-- These are the first-class way to flip config.paused, so operators never hand-edit the catalog.
-- drain_step/drain_all ignore the flag, so you can still drive the drain by hand while paused.
create or replace function pgpm.resume(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = false where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

create or replace function pgpm.pause(p_parent regclass)
returns void language plpgsql as $$
begin
  update pgpm.config set paused = true where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- renamed maintenance -> maintain / maintenance_all -> maintain_all (completes the obtain/drain/retain
-- rhyme). Drop the old names so re-running the installer over a prior version does not strand them.
drop function if exists pgpm.maintenance(regclass);
drop procedure if exists pgpm.maintenance_all();

create or replace function pgpm.maintain(p_parent regclass)
returns text language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0; v_dropped int := 0; v_drain text := 'skipped'; v_restored int := 0; v_suspended int := 0;
  v_refine text := 'skipped'; v_refine_child name;
  v_note text := '';
  v_batch int := null; v_ckpt bigint; v_congested boolean; v_budget int;
  v_now_lsn pg_lsn; v_now_ts timestamptz; v_secs numeric; v_obs_bps numeric;
  v_waiters int; v_wal_cong boolean; v_amb_cong boolean; v_reason text;
  v_lock_surge boolean; v_lock_abs boolean; v_amb_baseline numeric;
  v_io_time numeric; v_io_blks bigint; v_io_lat numeric; v_io_surge boolean; v_io_baseline numeric;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then return 'paused'; end if;

  -- Maintenance is a background janitor; it must NEVER block -- let alone deadlock -- the live
  -- workload. Each step is isolated in its own subtransaction, and a step that loses a lock race
  -- is DEFERRED (retried next tick) WITHOUT aborting the drain.
  --
  -- obtain/retain get a VERY SHORT lock_timeout. Obtaining a future partition's first step
  -- (ADD CONSTRAINT on the default, for the scan-skip path) takes ACCESS EXCLUSIVE on the default
  -- -- which the live workload's inserts hold almost continuously. A long timeout there is doubly
  -- bad: it blocks the workload for the whole wait (the pending ACCESS EXCLUSIVE queues every new
  -- locker behind it), AND if it does win the lock it goes on to VALIDATE-scan the entire default
  -- before the CREATE -- a scan that is wasted whenever the CREATE then can't get its lock. Failing
  -- fast makes a deferral nearly free: no long block, and it bails before that scan. obtain is
  -- optional (the future cells aren't written yet; the DEFAULT catches anything), so it simply
  -- retries when the workload next has a gap.
  perform set_config('lock_timeout', '200ms', true);

  -- obtain back-off: once a deferral happens, don't retry every tick -- under sustained write
  -- contention obtain can't win the lock for minutes, and each attempt risks a wasted default
  -- scan. Wait out a back-off window; the future cells aren't written yet (the DEFAULT catches
  -- them), so deferring obtain is harmless. A successful obtain clears the back-off.
  if coalesce(cfg.obtain_retry_after, '-infinity'::timestamptz) <= clock_timestamp() then
    begin
      v_made := pgpm.obtain(p_parent);
      if cfg.obtain_retry_after is not null then
        update pgpm.config set obtain_retry_after = null where parent_table = p_parent;
      end if;
    exception when others then
      v_note := v_note || ' obtain_deferred';
      update pgpm.config set obtain_retry_after = clock_timestamp() + interval '30 seconds'
        where parent_table = p_parent;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'obtain_skip', left(sqlerrm, 200));
    end;
  else
    v_note := v_note || ' obtain_backoff';
  end if;

  begin
    v_dropped := pgpm.retain(p_parent);
  exception when others then
    v_note := v_note || ' retain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'retain_skip', left(sqlerrm, 200));
  end;

  -- Adaptive feathering (mode 2, REDESIGN.md): ride the per-tick drain budget just under the WAL
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
    -- Backoff signals, OR'd (see DESIGN sec 8): the WAL-rate signal (producer self-limit against
    -- checkpoint storms) and the ambient signal (consumer priority -- yield when the drain is crowding
    -- the workload, which the WAL rate cannot see). Any fires => halve. The ambient signal has two
    -- role-independent terms (no pg_monitor): a lock-wait surge (pg_locks) and an I/O-latency surge
    -- (pg_stat_database), each self-calibrating against its own learned EWMA baseline, OR'd with the
    -- optional absolute lock-wait cap. A surge damps that baseline's smoothing 10x so a transient spike
    -- barely moves it (keeps the surge visible) while a sustained shift is still relearned. Baselines
    -- only advance when the signal is enabled (drain_ambient_factor > 0).
    v_wal_cong := pgpm._feather_congested(
                    v_obs_bps, pgpm._wal_sustainable_bps(), cfg.drain_wal_high_water,
                    cfg.drain_ckpt_seen is not null and v_ckpt > cfg.drain_ckpt_seen);
    -- term 1: lock-wait pressure (role-independent count from pg_locks)
    v_waiters  := pgpm._ambient_lock_waiters();
    v_lock_surge := pgpm._ambient_surge(v_waiters, cfg.drain_ambient_baseline,
                                        cfg.drain_ambient_factor, cfg.drain_ambient_floor);
    v_lock_abs   := pgpm._ambient_congested(v_waiters, cfg.drain_ambient_max_waiters);
    -- term 2: read-I/O latency (ms/block) over the interval since the last tick (inert if track_io_timing off)
    select s.blk_read_time::numeric, s.blks_read
      into v_io_time, v_io_blks
      from pg_stat_database s where s.datname = current_database();
    v_io_lat   := pgpm._ambient_io_latency(cfg.drain_io_read_time, cfg.drain_io_blks_read, v_io_time, v_io_blks);
    v_io_surge := pgpm._ambient_io_surge(v_io_lat, cfg.drain_ambient_io_baseline, cfg.drain_ambient_factor, 1.0);
    v_amb_cong := v_lock_surge or v_lock_abs or v_io_surge;
    v_amb_baseline := cfg.drain_ambient_baseline;
    v_io_baseline  := cfg.drain_ambient_io_baseline;
    if cfg.drain_ambient_factor > 0 then
      v_amb_baseline := pgpm._ambient_baseline_next(
        cfg.drain_ambient_baseline, v_waiters,
        case when v_lock_surge then cfg.drain_ambient_alpha / 10 else cfg.drain_ambient_alpha end);
      if v_io_lat is not null then
        v_io_baseline := pgpm._ambient_baseline_next(
          cfg.drain_ambient_io_baseline, v_io_lat,
          case when v_io_surge then cfg.drain_ambient_alpha / 10 else cfg.drain_ambient_alpha end);
      end if;
    end if;
    v_congested := v_wal_cong or v_amb_cong;
    v_reason   := coalesce(nullif(concat_ws('+',
                    case when v_wal_cong then 'wal' end,
                    case when v_lock_surge or v_lock_abs then 'lock' end,
                    case when v_io_surge then 'io' end), ''), 'probe');
    v_budget    := pgpm._aimd_next(
                     coalesce(cfg.drain_budget, cfg.drain_batch),       -- start optimistic at the ceiling
                     v_congested,
                     greatest(1, cfg.drain_batch / 16),                 -- floor: minimum forward progress
                     cfg.drain_batch,                                   -- ceiling: never exceed the tuned rate
                     greatest(1, cfg.drain_batch / 8));                 -- additive recovery step
    v_batch := v_budget;
  end if;

  -- Auto-refine target: the oldest FROZEN coarse child (if auto-refine is on). A coarse child (hi > one
  -- step past lo) is frozen once its whole range is at/below the current grid floor (no live write still
  -- lands in it). Found here, before the drain, only so the auto-refine block below can use it.
  if cfg.refine_to is not null then
    execute format(
      'select child_name from pgpm.part p where p.parent_table = %L::regclass and p.attached'
      || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo))'
      || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',
      p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step,
      cfg.control_kind,
      pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, pgpm._frontier_native(p_parent)),
      pgpm._native_type(cfg.control_kind))
      into v_refine_child;
  end if;

  -- The drain IS the conversion: give its (infrequent) partition attach room to win its lock,
  -- so progress isn't starved. Its scans run under SHARE UPDATE EXCLUSIVE (non-blocking to the
  -- workload); only the brief final ATTACH needs a stronger lock.
  perform set_config('lock_timeout', '3s', true);
  begin
    -- Suspend (re-drop) any preserve-managed FK that is currently live BEFORE the DRAIN moves referenced
    -- rows: the drain deletes a closed-tail row out of the DEFAULT and re-inserts it through an unattached
    -- child, so the row is briefly outside the parent and a live NO ACTION FK would reject the move (a
    -- CASCADE/SET NULL would silently honour it). Gated on a non-empty closed tail. Auto-refine does NOT
    -- need this: it COPIES without deleting, so referenced rows never leave the visible parent -- so the
    -- suspend is no longer forced for a pending refine. Shares the drain's subtransaction.
    v_suspended := pgpm.suspend_incoming_fks(p_parent);
    v_drain := pgpm.drain_step(p_parent, v_batch);
  exception when others then
    v_drain := 'deferred';
    v_note := v_note || ' drain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'drain_skip', left(sqlerrm, 200));
  end;

  -- Commit the adaptive step ONLY when the drain did work (moved/reclaimed rows or attached). A
  -- fully-drained, idle table must not churn config or log a budget row every tick (a standing steward
  -- ticks forever). Leaving the ckpt baseline stale across an idle gap just makes the next active tick
  -- treat any idle-period checkpoints as congestion and back off once -- the safe direction.
  if cfg.drain_adaptive and (v_drain like 'moved:%' or v_drain like 'attached:%' or v_drain like 'reclaimed:%') then
    update pgpm.config set drain_budget = v_budget, drain_ckpt_seen = v_ckpt,
                           drain_wal_lsn = v_now_lsn, drain_wal_at = v_now_ts,
                           drain_ambient_baseline = v_amb_baseline,
                           drain_ambient_io_baseline = v_io_baseline,
                           drain_io_read_time = v_io_time, drain_io_blks_read = v_io_blks
      where parent_table = p_parent;
    v_note := v_note || format(' adaptive[%s %s]', v_budget, v_reason);
    insert into pgpm.log (parent_table, action, rows, method)
      values (p_parent, 'drain_budget', v_budget, v_reason);
  end if;

  -- Auto-refine (REDESIGN.md sec 12): feather the oldest frozen coarse child (found up front as
  -- v_refine_child) one budget-sized COPY microbatch toward refine_to per tick, under the same adaptive
  -- budget as the drain. Isolated in its own subtransaction; a lock race or a soft status just retries next
  -- tick. Unlike the drain, refine COPIES and never deletes: the source stays whole and attached until the
  -- atomic swap, so it never moves a referenced row out of the parent, never opens the snapshot() gap, and
  -- needs NO FK leash -- it is NOT gated on a live preserve FK and runs whether or not one is suspended.
  if v_refine_child is not null then
    begin
      v_refine := pgpm.refine_step(p_parent, v_refine_child, cfg.refine_to, v_batch);
    exception when others then
      v_refine := 'deferred';
      v_note := v_note || ' refine_deferred';
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'refine_skip', left(sqlerrm, 200));
    end;
  elsif cfg.refine_to is not null then
    v_refine := 'none';   -- auto-refine on, but no frozen coarse child to work
  end if;

  -- Re-add any incoming FKs that transmute(..., 'preserve') dropped, now against the new parent, AFTER
  -- both the drain and the refine have moved this tick. restore_incoming_fks self-gates on quiescence (no
  -- closed rows AND no in-flight child), so while a multi-tick refine is mid-flight it stays a no-op and
  -- the FK remains suspended (RI off, surfaced by status().fks_suspended), re-adding only once the refine
  -- has swapped in its fine children. Isolated: a hiccup here never aborts progress.
  begin
    v_restored := pgpm.restore_incoming_fks(p_parent);
  exception when others then
    v_note := v_note || ' restore_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_fk_skip', left(sqlerrm, 200));
  end;

  return format('obtained=%s dropped=%s drain=%s suspended_fk=%s restored_fk=%s refine=%s%s',
                v_made, v_dropped, v_drain, v_suspended, v_restored, v_refine, v_note);
end;
$$;

create or replace procedure pgpm.maintain_all()
language plpgsql as $$
declare r record;
begin
  for r in select parent_table from pgpm.config loop
    perform pgpm.maintain(r.parent_table);
  end loop;
end;
$$;

-- schedule()/unschedule(): a thin convenience wrapper around pg_cron for the one job pgpm needs, so the
-- operator does not hand-write the cron incantation. pgpm never schedules on its own (transmute stays
-- pg_cron-free, and the drain can be driven by hand with drain_all/maintain); this is the deliberate,
-- discoverable way to turn the scheduled lifecycle on. One canonical job named 'pgpm' calls
-- maintain_all() for ALL managed tables, so it is scheduled once, not per table, and re-scheduling
-- updates the interval rather than duplicating. It targets current_database() via schedule_in_database,
-- so the job runs against the database pgpm lives in whether or not that is the cron database. The cron
-- calls are dynamic (EXECUTE) on purpose: the cron schema is only resolved at call time, so this file
-- still installs cleanly where pg_cron is not enabled yet. Run it FROM the database where pg_cron is
-- installed (its `cron` schema must be present); uninstall.sql already unschedules every 'pgpm%' job.
-- p_every is a pg_cron schedule: standard 5-field cron ('* * * * *' = every minute, the default;
-- '*/5 * * * *' = every 5 min) or pg_cron's seconds interval ('30 seconds'). Note pg_cron does NOT
-- accept '1 minute'-style interval strings; minute cadence goes through cron syntax.
create or replace function pgpm.schedule(p_every text default '* * * * *')
returns bigint language plpgsql as $$
declare v_jobid bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'pg_partition_magician: pg_cron is not installed in this database; enable it (create extension pg_cron) to schedule maintenance, or drive the drain by hand with drain_all/maintain';
  end if;
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm', p_every, 'call pgpm.maintain_all()', current_database())
    into v_jobid;
  return v_jobid;
end;
$$;

create or replace function pgpm.unschedule()
returns int language plpgsql as $$
declare v_n int := 0;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return 0;   -- nothing scheduled if pg_cron is not here
  end if;
  execute 'select count(*)::int from (select cron.unschedule(jobid) from cron.job '
       || 'where jobname = ''pgpm'' and database = current_database()) s' into v_n;
  return v_n;
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
-- down. This is the tier-2 safety check for retaining by time against an id partition
-- key (REDESIGN.md): mapping "older than T" to an id boundary is only sound when id and
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

-- status(): the operator's at-a-glance view. Beyond the static config it surfaces two things that let
-- a WEDGED drain be told apart from a merely slow one (issue #92): closed_rows, the drainable backlog
-- (rows in the DEFAULT below the open interval, via check_default), and a stall signal --
-- last_drained (when the drain last made progress) plus drain_skips (deferrals logged SINCE that
-- progress). A non-zero closed_rows with a stale/null last_drained and a climbing drain_skips is a
-- wedged drain (e.g. the upsert/duplicate-key wedge); a slow-but-healthy drain shows closed_rows
-- falling and drain_skips ~0. default_rows stays the total (open + closed) for contrast.
-- inflight_partitions is the count of drain children created but not yet attached (issue #94): a
-- standing non-zero value alongside a stale last_drained means an attach is stalled (its rows are
-- durable but not visible through the parent until it attaches; use snapshot() for a complete read).
-- fks_suspended / fks_unvalidated surface preserve-managed incoming FK state (issue #95):
-- fks_suspended = incoming FKs currently DROPPED (RI off on the referencing table -- expected during a
-- drain, a standing value if the drain never finishes); fks_unvalidated = FKs re-added NOT VALID
-- (enforcing new writes) but blocked from full validation by pre-existing orphans (see
-- incoming_fk_orphans() / validate_incoming_fks()).
-- dropped/recreated (not CREATE OR REPLACE) because the redesign widens the return shape with
-- coarse_partitions + history_unrefined (REDESIGN.md section 14).
drop function if exists pgpm.status();
create or replace function pgpm.status()
returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  default_rows bigint, closed_rows bigint,
  default_oldest text, newest_bound text, last_drained timestamptz, drain_skips bigint,
  fks_suspended bigint, fks_unvalidated bigint, history_unrefined boolean
)
language plpgsql as $$
declare
  r pgpm.config; v_nsp name; v_np bigint; v_coarse bigint; v_inflight bigint; v_new text;
  v_drows bigint; v_closed bigint; v_old text;
  v_last_drained timestamptz; v_last_progress_id bigint; v_skips bigint;
  v_fks_susp bigint; v_fks_unval bigint;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;
    -- backlog via the canonical check_default: default_rows (total), closed_rows (drainable now), oldest
    select cd.default_rows, cd.closed_rows, cd.oldest into v_drows, v_closed, v_old
      from pgpm.check_default(r.parent_table) cd;
    -- n_partitions = attached (real) partitions; coarse_partitions = the un-refined coarse children (a
    -- wider-than-one-step range, REDESIGN.md section 14) -- the refinement backlog; inflight = the
    -- not-yet-attached drain/refine children.
    select count(*) filter (where attached),
           count(*) filter (where attached
                            and pgpm._native_gt(r.control_kind, hi, pgpm._grid_next(r.control_kind, r.partition_step, lo))),
           count(*) filter (where not attached)
      into v_np, v_coarse, v_inflight from pgpm.part where parent_table = r.parent_table;
    execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass and attached',
                   pgpm._native_type(r.control_kind), r.parent_table::text) into v_new;
    -- drain progress vs stall, from the append-only log. drain_skips counts deferrals logged AFTER the
    -- last progress, ordered by the log's monotonic id (robust even when many rows share one tick's
    -- now()). retain_reclaim counts as progress (issue #91), like drain_move/drain_attach.
    select max(at), max(id) into v_last_drained, v_last_progress_id from pgpm.log
      where parent_table = r.parent_table and action in ('drain_move', 'drain_attach', 'retain_reclaim');
    select count(*) into v_skips from pgpm.log
      where parent_table = r.parent_table and action = 'drain_skip' and id > coalesce(v_last_progress_id, 0);
    -- preserve-managed incoming FK state: dropped (RI off) vs re-added-but-not-validated (orphan-blocked)
    select count(*) filter (where restored_at is null),
           count(*) filter (where restored_at is not null and validated_at is null)
      into v_fks_susp, v_fks_unval
      from pgpm.dropped_fk where parent_table = r.parent_table;
    parent := r.parent_table; control_kind := r.control_kind; partition_step := r.partition_step;
    obtain := r.obtain; retain := r.retain; paused := r.paused; n_partitions := v_np;
    coarse_partitions := v_coarse; inflight_partitions := v_inflight; history_unrefined := v_coarse > 0;
    default_rows := v_drows; closed_rows := v_closed; default_oldest := v_old; newest_bound := v_new;
    last_drained := v_last_drained; drain_skips := v_skips;
    fks_suspended := v_fks_susp; fks_unvalidated := v_fks_unval;
    return next;
  end loop;
end;
$$;

-- snapshot(): a read-consistency escape hatch for the drain visibility gap. THE GAP: the drain moves a
-- closed interval out of the DEFAULT into a brand-new child that is created STANDALONE and only ATTACHed
-- once the whole interval has moved (see drain_step). Between the first microbatch and that attach, the
-- already-moved rows are durable but live in an UNATTACHED table, so they are NOT reachable through the
-- parent: a plain `select ... from parent` mid-drain UNDERCOUNTS the interval being drained (by however
-- many rows have moved so far). This is inherent -- Postgres has no way to make an unattached relation
-- visible through the parent, and will not attach a partition while the DEFAULT still holds rows in its
-- range (chicken-and-egg). snapshot() returns the COMPLETE set during a drain -- the parent UNION every
-- in-flight, not-yet-attached child -- so a consistency-sensitive reader (a COUNT, a logical backup, a
-- reconciliation) sees the moved rows too:
--
--   select count(*) from pgpm.snapshot(null::public.events);
--
-- It is a set-returning function whose row type is the parent's: the regclass cannot be inferred from a
-- runtime value (return shape is fixed at plan time), so the caller passes the rowtype as a typed-NULL
-- anchor, and snapshot() derives the table from it (pg_typeof -> pg_type.typrelid -> the table). Two
-- honest costs, both inherent and documented: (1) it is an OPTIMIZATION FENCE -- the in-flight child set
-- is dynamic so the body is dynamic SQL in an SRF, meaning a WHERE on top does NOT push down into the
-- union arms or use the child's CHECK-constraint exclusion; it materializes the union, then filters.
-- Fine for COUNT/full reads; for heavily-filtered reads on a large table a manual `select ... from
-- parent union all select ... from <child>` plans better. (2) It does NOTHING for writes: an
-- INSERT/UPDATE/DELETE through the parent that targets an already-moved row is a 0-row no-op until the
-- interval attaches -- there is no fix, by design. Upside vs a stored view: it is ALWAYS FRESH (it
-- rediscovers the in-flight child on every call, so it can neither double-count an attached child nor
-- miss a newly-started one) and leaves no object behind. Single-batch intervals and drain_all (one
-- transaction) never open the gap.
create or replace function pgpm.snapshot(p_rowtype anyelement)
returns setof anyelement language plpgsql as $$
declare cfg pgpm.config; v_parent regclass; v_nsp name; v_rel name; v_arms text; v_child name;
begin
  -- derive the parent table from the rowtype anchor: a table's composite rowtype links 1:1 back to it.
  select c.oid into v_parent
    from pg_type t join pg_class c on c.oid = t.typrelid
   where t.oid = pg_typeof(p_rowtype)::oid and c.relkind in ('r', 'p');
  if v_parent is null then
    raise exception 'pg_partition_magician: snapshot() needs a table rowtype anchor, e.g. pgpm.snapshot(null::public.events)';
  end if;
  select * into cfg from pgpm.config where parent_table = v_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', v_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = v_parent;

  -- the parent already covers the DEFAULT and every attached partition; add every in-flight DRAIN child:
  -- a standalone table matching the parent's child-partition naming that is NOT yet attached (same shape as
  -- the orphan guard). Crucially, EXCLUDE a refine copy-child -- an unattached child whose range is contained
  -- in an attached partition (the coarse source it is being copied out of). Its rows are still present in
  -- that attached source, so unioning the copy would DOUBLE-COUNT (refine copies, never moves -- so unlike a
  -- drain child its rows are not absent from the parent). A true drain child sits in no attached partition's
  -- range, so it is kept; a true orphan (not in pgpm.part) is also kept, conservatively.
  v_arms := format('select * from %s', v_parent::text);
  for v_child in
    select c.relname from pg_class c
     where c.relnamespace = (select n.oid from pg_namespace n where n.nspname = v_nsp)
       and c.relkind = 'r' and starts_with(c.relname, v_rel || '_p')
       and case when cfg.control_kind = 'id'
                then substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{19}$'
                else substr(c.relname, length(v_rel) + 3) ~ '^[0-9]{4}(_[0-9]+)*$' end
       and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
       and not exists (                                            -- skip refine copies (rows still in the source)
             select 1 from pgpm.part cp
              join pgpm.part ap on ap.parent_table = cp.parent_table and ap.attached
             where cp.parent_table = v_parent and cp.child_name = c.relname
               and not pgpm._native_gt(cfg.control_kind, ap.lo, cp.lo)   -- ap.lo <= cp.lo
               and not pgpm._native_gt(cfg.control_kind, cp.hi, ap.hi))  -- cp.hi <= ap.hi
  loop
    v_arms := v_arms || format(' union all select * from %I.%I', v_nsp, v_child);
  end loop;

  return query execute v_arms;
end;
$$;

-- restore_incoming_fks(): re-add the incoming FKs that transmute(..., p_incoming_fks => 'preserve')
-- recorded, pointing them back at the new partitioned parent, but only once it is SAFE. Safe = the
-- conversion is quiescent: the closed tail is fully drained (no closed rows linger in the DEFAULT) and
-- no in-flight, not-yet-attached child partition exists. The drain moves rows out of the DEFAULT through
-- such a child, during which a referenced row is briefly outside the parent and a live NO ACTION FK
-- would reject the move (see REDESIGN.md), so the FK must stay dropped until the drain is idle.
-- The re-add is split (issue #95): `ADD CONSTRAINT ... NOT VALID` (enforces every new write, always
-- succeeds) committed separately from `VALIDATE` (scans existing rows, may fail on an orphan written
-- during the suspend window). A failed VALIDATE leaves the FK NOT VALID -- enforcing new writes,
-- surfaced via status().fks_unvalidated -- rather than rolling the re-add back into a permanent silent
-- brick. Returns the number re-added; 0 (a no-op) while the drain is still in flight, so `maintain`
-- can call it every tick and it acts only when the table is ready.
create or replace function pgpm.restore_incoming_fks(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_closed bigint; v_inflight name;
  r pgpm.dropped_fk%rowtype; v_n int := 0; v_is_part boolean; v_readded boolean;
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

  -- gate 2: no in-flight (un-attached) DRAIN child mid-drain (same shape as transmute's orphan guard). A
  -- refine copy-child is EXCLUDED (its range is contained in an attached partition): refine copies without
  -- deleting, so the referenced rows never leave the visible parent, and a copy-refine never needs the FK
  -- suspended -- so it must not hold a drain-suspended FK off either (that would reopen the RI window the
  -- copy design closes). Only a true drain child, in no attached partition's range, blocks the re-add.
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
     and not exists (                                            -- a refine copy is not an absent-row child
           select 1 from pgpm.part cp
            join pgpm.part ap on ap.parent_table = cp.parent_table and ap.attached
           where cp.parent_table = p_parent and cp.child_name = c.relname
             and not pgpm._native_gt(cfg.control_kind, ap.lo, cp.lo)   -- ap.lo <= cp.lo
             and not pgpm._native_gt(cfg.control_kind, cp.hi, ap.hi))  -- cp.hi <= ap.hi
   limit 1;
  if v_inflight is not null then return 0; end if;

  -- Re-add each dropped FK, then attempt to VALIDATE it once -- in SEPARATE subtransactions, so a
  -- VALIDATE that fails on a pre-existing orphan does NOT roll back the re-add (issue #95). A re-added
  -- NOT VALID FK already enforces RI for every NEW write; only pre-existing rows go unverified. So the
  -- FK comes back the instant the drain is idle and can never be permanently bricked by an orphan
  -- written during the suspend window; the orphans (if any) are surfaced by status().fks_unvalidated /
  -- pgpm.incoming_fk_orphans() and cleared with pgpm.validate_incoming_fks() once the operator removes
  -- them. The recorded definition already names the parent (captured before the rename).
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is null order by id loop
    v_is_part := (select relkind from pg_class where oid = r.referencing_table) = 'p';
    v_readded := false;
    begin
      if v_is_part then
        -- self-referential / partitioned referencer: Postgres forbids NOT VALID FKs here, so add it
        -- validating in one step (all-or-nothing). A pre-existing orphan leaves it DROPPED and logged,
        -- without bricking the other FKs; self-ref / partitioned-referencer FKs are typically small.
        execute format('alter table %s add constraint %I %s',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = now() where id = r.id;
      else
        execute format('alter table %s add constraint %I %s not valid',
                       r.referencing_table::text, r.constraint_name, r.definition);
        update pgpm.dropped_fk set restored_at = now(), validated_at = null where id = r.id;
      end if;
      v_readded := true;
      v_n := v_n + 1;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'restore_incoming_fk', r.constraint_name);
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'restore_incoming_fk_failed', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
    -- validate the just-re-added NOT VALID FK once; a pre-existing orphan keeps it NOT VALID (still
    -- enforcing new writes) and is surfaced, NOT rolled back into the dropped state.
    if v_readded and not v_is_part then
      begin
        execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
        update pgpm.dropped_fk set validated_at = now() where id = r.id;
      exception when others then
        insert into pgpm.log (parent_table, action, method)
          values (p_parent, 'validate_incoming_fk_blocked', left(r.constraint_name || ': ' || sqlerrm, 200));
      end;
    end if;
  end loop;
  return v_n;
end;
$$;

-- validate_incoming_fks(): finish validating any preserve-managed FK that was re-added NOT VALID but
-- not yet validated (its pre-existing orphans blocked it). Run after clearing the orphans
-- (pgpm.incoming_fk_orphans() lists the counts). Each VALIDATE is isolated, so one still-blocked FK
-- does not stop the others; returns the number newly validated. maintenance does NOT auto-retry the
-- VALIDATE every tick (it would re-scan the referencing table each time), so this is the deliberate
-- operator step to fully validate once the data is clean.
create or replace function pgpm.validate_incoming_fks(p_parent regclass)
returns int language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null order by id loop
    begin
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
      update pgpm.dropped_fk set validated_at = now() where id = r.id;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'validate_incoming_fk', r.constraint_name);
      v_n := v_n + 1;
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'validate_incoming_fk_blocked', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
$$;

-- incoming_fk_orphans(): for each preserve-managed FK that is re-added but not yet validated, count the
-- orphan rows blocking validation -- referencing rows whose (non-null) FK columns match no parent key.
-- The operator uses this to find and clear what blocks validate_incoming_fks(). Reads the column
-- mapping from the live (NOT VALID) constraint in pg_constraint; handles composite FKs.
create or replace function pgpm.incoming_fk_orphans(p_parent regclass)
returns table (referencing_table regclass, constraint_name name, orphan_rows bigint)
language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; c pg_constraint%rowtype; v_join text; v_notnull text; v_cnt bigint;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null order by id loop
    select * into c from pg_constraint
      where conrelid = r.referencing_table and conname = r.constraint_name and contype = 'f';
    if not found then continue; end if;
    select string_agg(format('r.%I = p.%I', fa.attname, pa.attname), ' and '),
           string_agg(format('r.%I is not null', fa.attname), ' and ')
      into v_join, v_notnull
      from unnest(c.conkey, c.confkey) with ordinality as u(fk_att, pk_att, ord)
      join pg_attribute fa on fa.attrelid = c.conrelid and fa.attnum = u.fk_att
      join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = u.pk_att;
    execute format('select count(*)::bigint from %s r where %s and not exists (select 1 from %s p where %s)',
                   c.conrelid::regclass::text, v_notnull, c.confrelid::regclass::text, v_join) into v_cnt;
    referencing_table := r.referencing_table; constraint_name := r.constraint_name; orphan_rows := v_cnt;
    return next;
  end loop;
end;
$$;

-- suspend_incoming_fks(): the inverse of restore. When the closed tail has drain work pending, re-drop
-- any preserve-managed FK that is currently live, so the drain never moves a referenced row past a
-- live FK. That matters beyond a mere stall: a live ON DELETE CASCADE / SET NULL FK would silently
-- delete or null the referencing rows as the drain removes their referent from the DEFAULT (verified
-- on PG 17). maintenance calls this before each drain step; restore_incoming_fks re-adds once the
-- tail is drained, maintaining the invariant "a managed FK is live iff the closed tail is empty".
-- A no-op (returns 0) when the closed tail is empty, so it is safe to call every tick.
create or replace function pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false)
returns int language plpgsql as $$
declare v_closed bigint; r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is not null) then
    return 0;
  end if;
  -- Normally gated on drain work (closed tail rows): no work => leave live FKs in place. p_force overrides
  -- the gate, for the caller (maintain's auto-refine) that is about to move referenced rows out of a
  -- frozen coarse child even though the closed tail is empty.
  if not p_force then
    select closed_rows into v_closed from pgpm.check_default(p_parent);
    if coalesce(v_closed, 0) = 0 then return 0; end if;
  end if;
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
    update pgpm.dropped_fk set restored_at = null, validated_at = null where id = r.id;
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'suspend_incoming_fk', r.constraint_name);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at, attached from pgpm.part order by parent_table, lo;
