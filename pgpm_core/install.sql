-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL range-partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling). No compiled
--     extension. Install with: psql -f this_file.sql.  Schema: pgpm.
--   * Manages the full lifecycle of native RANGE-partitioned tables: transmute an
--     existing (possibly huge, live) table online, obtain ahead of the write
--     frontier, archive, retain, regrain, all via maintenance.
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
  obtain          int         not null default 30,
  retain        text,                    -- interval (time/uuidv7) | bigint count (id); null = keep
  regrain_batch    int         not null default 5000,   -- rows per regrain COPY microbatch
  paused           boolean     not null default true,
  created_at       timestamptz not null default now(),
  -- when maintenance may next attempt obtain for this parent. Under sustained write contention obtain
  -- keeps losing the ACCESS EXCLUSIVE race on the parent, so on a deferral maintenance backs it off
  -- instead of retrying every tick. null = attempt now.
  obtain_retry_after timestamptz,
  -- optional block budget for a regrain microbatch: cap it at ~this many heap+TOAST blocks (translated
  -- to a row limit via the coarse child's average bytes/row), so wide rows cannot make a single batch
  -- huge. null = cap by regrain_batch rows only (default).
  regrain_max_blocks int
);
-- upgrade path for installs that predate these columns
alter table pgpm.config add column if not exists obtain_retry_after timestamptz;
-- #288: the fourteen adaptive-feathering columns are gone with the closed loop they fed, and so are
-- keep_default and default_table. drain_batch/drain_max_blocks survive under regrain_* names: they are
-- regrain's microbatch knobs now, and the old names described a machine that no longer exists.
alter table pgpm.config drop column if exists drain_adaptive;
alter table pgpm.config drop column if exists drain_budget;
alter table pgpm.config drop column if exists drain_ckpt_seen;
alter table pgpm.config drop column if exists drain_wal_lsn;
alter table pgpm.config drop column if exists drain_wal_at;
alter table pgpm.config drop column if exists drain_wal_high_water;
alter table pgpm.config drop column if exists drain_ambient_max_waiters;
alter table pgpm.config drop column if exists drain_ambient_factor;
alter table pgpm.config drop column if exists drain_ambient_alpha;
alter table pgpm.config drop column if exists drain_ambient_floor;
alter table pgpm.config drop column if exists drain_ambient_baseline;
alter table pgpm.config drop column if exists drain_ambient_io_baseline;
alter table pgpm.config drop column if exists drain_io_read_time;
alter table pgpm.config drop column if exists drain_io_blks_read;
alter table pgpm.config drop column if exists keep_default;
alter table pgpm.config drop column if exists default_table;
alter table pgpm.config add column if not exists regrain_batch int not null default 5000;
alter table pgpm.config add column if not exists regrain_max_blocks int;
-- auto-regrain (REDESIGN.md section 12): when set, maintenance feathers the oldest frozen coarse child
-- toward this target step, one budget-sized microbatch per tick. null = off (regrain is operator-driven).
alter table pgpm.config add column if not exists regrain_to text;
-- regrain copy progress (REDESIGN.md section 10): the NATIVE-grid lo of the sub-range currently being
-- copied out of the coarse child under regraining -- a cross-tick high-water mark. regrain COPIES (never
-- deletes), so the source never shrinks and cannot drive progress the way the drain's deletes do; this
-- cursor is the explicit progress state instead. null = no regrain in flight; reset to null at the swap.
alter table pgpm.config add column if not exists regrain_cursor text;
-- retain() pacing (issue #189): cap how many eligible partitions ONE retain() call will attempt
-- (write-block, archive-coverage check, drop), so an aged-out backlog spreads across maintenance
-- ticks (each tick its own transaction via pg_cron) instead of one call carrying the whole backlog
-- -- the drain_batch shape, applied to drops. The cap bounds ATTEMPTS, oldest first: with an
-- unexpected drop failure at the head, the partitions behind it are not attempted that call
-- (bounded per-tick work is the point; the wedge is surfaced by status().retain_drop_failures
-- alongside a flat retain_backlog -- issue #238). null = unbounded (prior behavior). A table whose
-- chunked archiving is genuinely still catching up on a large backlog is not a wedge at all: that is
-- retain_backlog falling tick over tick with retain_drop_failures flat at zero.
alter table pgpm.config add column if not exists retain_batch int;
-- the pluggable archive strategy (issue #236): null = strategy 'none' (no archiving, drop as soon as
-- write-blocked). regprocedure (not text/regproc) so a bad reference is refused right here at
-- assignment, not discovered later when a maintenance tick tries to call it. Contract:
-- archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns pgpm.archive_result,
-- called once per tick, expected to make bounded incremental progress and report how much of
-- [lo, hi) is now durably archived (not to finish the whole range in one call). retire()'s drop
-- precondition consults this via pgpm._archive_fully_covered (#238) -- see
-- pgpm._run_archive_strategy and pgpm._archive_noop below.
alter table pgpm.config add column if not exists archive_fn regprocedure;
-- byte-budget chunking knobs (issue #237, porting archive._next_range_byte_budget's own
-- c_byte_budget/c_probe_sample constants): archive_byte_budget estimates how many rows make up
-- roughly this many bytes (via a sampled average row width), and archive_probe_sample caps how many
-- rows that sample scans. Same defaults as the original. Ignored entirely by a 'none' strategy.
alter table pgpm.config add column if not exists archive_byte_budget bigint not null default 8 * 1024 * 1024;
alter table pgpm.config add column if not exists archive_probe_sample int not null default 1000;

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
  -- When retirement of this child BEGAN -- set as retire() dispatches a CONCURRENT DETACH for it, never
  -- refreshed by a retry, and cleared with the row when the drop completes (issue #268). It doubles as
  -- the tiebreak that keeps exactly one detach in flight, which is why it must not move. Retiring a REFERENCED partition cannot happen in one step: a bare
  -- DROP is refused on the referencing table's per-partition constraint, and the DETACH that severs
  -- it must be CONCURRENT (a plain one holds ACCESS EXCLUSIVE on the managed parent for the whole
  -- O(referencing table) scan) -- which PostgreSQL refuses to run from a function, so pgpm dispatches
  -- it to pg_cron and finishes on a later tick. This marker is what makes that recoverable: a detach
  -- left pending by a dead backend is finalized by _detach_reap, and this says whether the retirement
  -- behind it was pgpm's to complete or an operator's to keep. null for every unreferenced partition,
  -- which never leaves the one-step bare-DROP path at all.
  retiring_at  timestamptz,
  primary key (parent_table, child_name)
);
-- upgrade path for installs that predate these columns
alter table pgpm.part add column if not exists attached boolean not null default true;
alter table pgpm.part add column if not exists retiring_at timestamptz;

-- In-flight conversions (issue #275). transmute runs in three transactions -- add the bound, validate it,
-- cut over -- so that the O(rows) validation scan is not held under the ACCESS EXCLUSIVE lock the ADD
-- takes. The cost of that split is that a failure between phases leaves a live `pgpm_monolith_bound` CHECK
-- on the operator's table, which REJECTS any write outside [lo, hi) (a NOT VALID check still enforces new
-- rows). This table is what lets maintenance find and undo that: a half-converted table is not in
-- pgpm.config yet, because registration happens in the cutover, so there is nothing else to look it up by.
--
-- lo/hi are recorded so a resumed transmute reuses the SAME bound rather than recomputing one against a
-- frontier that has since moved.
create table if not exists pgpm.transmute_inflight (
  parent_table  regclass    not null primary key,
  nsp           name        not null,
  rel           name        not null,
  control_kind  text        not null,
  lo            text        not null,
  hi            text        not null,
  started_at    timestamptz not null default now()
);

-- The audit trail. NAMING RULE for `action`: non-success events are PREFIXED, never suffixed --
-- `skip_<mechanism>` for a deferral, `fail_<mechanism>` for a failure. So no non-success action is ever
-- a prefix-extension of the success it corresponds to, and both query styles are safe: `action =
-- 'obtain'` and `action like 'drain%'` match successes only, while `action like 'skip_%'` collects every
-- deferral across all mechanisms without enumerating them.
--
-- This was the other way round (`drain_skip`) and it bit: a guard asserting a tick had drained matched
-- `drain%`, which also matched `drain_skip` -- the exact row a tick writes when it was starved of its
-- locks and did nothing. The guard passed on a tick that had done no work. Do not reintroduce a suffix.
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
  -- The FK is dropped once, by the cutover, and re-added by restore_incoming_fks on a later tick; nothing
  -- in a maintenance tick suspends it again (#288 removed the drain that used to). Regrain's swap is the
  -- one remaining suspend/restore, and it does both inside one transaction. Splitting the re-add from the VALIDATE
  -- is what stops a pre-existing orphan from permanently bricking restoration: the FK comes back
  -- enforcing new writes immediately, and validation is a separate, loud step.
  restored_at         timestamptz,
  validated_at        timestamptz,
  dropped_at          timestamptz not null default now()
);
-- upgrade path for installs that predate these columns
alter table pgpm.dropped_fk add column if not exists restored_at timestamptz;
alter table pgpm.dropped_fk add column if not exists validated_at timestamptz;
-- #265: when a VALIDATE fails on a pre-existing orphan, do not retry it on the very next tick -- the
-- attempt re-scans the whole referencing table each time. Set a window instead, like config.obtain_retry_after.
alter table pgpm.dropped_fk add column if not exists validate_retry_after timestamptz;
-- backfill validated_at for FKs already re-added by an older pgpm (which validated in one step): mark
-- them validated iff the actual constraint is currently convalidated. Keyed off pg_constraint, not a
-- blanket update, so a genuinely re-added-NOT-VALID FK (convalidated = false) is never wrongly marked.
update pgpm.dropped_fk d set validated_at = d.restored_at
 where d.restored_at is not null and d.validated_at is null
   and exists (select 1 from pg_constraint c
                where c.conrelid = d.referencing_table and c.conname = d.constraint_name
                  and c.contype = 'f' and c.convalidated);

-- the lifecycle hook registry (issue #236's pre_drop event, superseded by config.archive_fn) is
-- fully retired (issue #240): retire() stopped consulting it at all in #238, and #239 gave
-- pgpm_archive's gate-only architecture (archive.file_gate, the registry's last real registrant) a
-- replacement on the archive_fn contract. Nothing depends on it anymore.
drop function if exists pgpm.hook_register(regclass, text, regprocedure, boolean);
drop function if exists pgpm.hook_unregister(regclass, text, regprocedure);
drop table if exists pgpm.hook;

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
  -- The relation can be gone: pgpm.config.parent_table is a regclass, and DROP TABLE on a managed parent
  -- leaves the row pointing at an oid with no pg_class entry (only untransmute clears pgpm state). A dead
  -- regclass renders as its BARE OID, which the EXECUTE below would interpolate into a FROM clause, so
  -- Postgres reported `syntax error at or near "17379"` -- blaming a syntax error on an integer, with
  -- nothing to tell an operator what actually happened (#296). Checked here rather than in each of the
  -- four callers, so obtain, _retain_boundary, regrain_step and maintain all inherit the real message.
  -- Deliberately BEFORE the control_kind branch: a `time` table returns now() without touching the
  -- relation, so it used to sail past this point and fail further downstream instead.
  if not exists (select 1 from pg_class c where c.oid = p_parent) then
    raise exception 'pg_partition_magician: managed table with oid % no longer exists (dropped without pgpm.untransmute); run pgpm.forget_missing() to clear its pgpm state', p_parent::oid;
  end if;
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

-- ANALYZE a freshly minted + bulk-loaded table so the planner has real row stats before anything relies
-- on it. A CREATE TABLE LIKE'd child that has just been INSERT'd into still shows reltuples = -1 (unknown)
-- until autovacuum catches up, so any plan that touches it in the interim -- a later regrain/drain batch,
-- the swap/attach, or a user query right after -- misplans against a phantom-empty table. That is exactly
-- the seqscan that made the from_hypertable cutover reconcile O(rows) (#164/#166). ANALYZE is sampled, so
-- its cost is bounded by default_statistics_target, not the table size; call it everywhere a table is
-- minted-then-populated, and (where possible) on the still-private child before any exclusive lock.
create or replace function pgpm._analyze(p_rel regclass)
returns void language plpgsql as $$
begin
  execute format('analyze %s', p_rel::text);
end;
$$;

-- Give a freshly minted child the PARENT's owner (#277). A table belongs to whoever created it, and
-- anything minted after the conversion is created by whatever role runs maintenance, so without this a
-- table's partitions drift into being owned by the maintenance role while the parent keeps the real owner.
--
-- The no-op guard is not just an optimisation: when maintenance already runs AS the owner the roles match
-- and no DDL is issued at all, so this never needs a privilege the caller lacks. When they differ, the
-- caller necessarily owns the parent already (adding a partition requires it), so the ALTER is permitted.
create or replace function pgpm._own_like_parent(p_parent regclass, p_child regclass)
returns void language plpgsql as $$
declare v_owner name;
begin
  select pg_get_userbyid(relowner) into v_owner from pg_class where oid = p_parent;
  if v_owner is distinct from (select pg_get_userbyid(relowner) from pg_class where oid = p_child) then
    execute format('alter table %s owner to %I', p_child::text, v_owner);
  end if;
end;
$$;

-- Create an EMPTY partition for native [p_lo, p_hi).
--
-- One statement. With the DEFAULT gone (#288) there is nothing to prove empty, so the whole
-- NOT VALID/VALIDATE exclusion dance is gone with it, along with the phase commits, the fixed
-- pgpm_obtain_excl name and the restart-on-leftover logic that #280 needed. CREATE TABLE ... PARTITION OF
-- against a parent with no default partition is pure catalog work: it takes a brief ACCESS EXCLUSIVE on
-- the parent and scans nothing.
create or replace function pgpm._create_partition(
  p_cfg pgpm.config, p_nsp name, p_rel name, p_default regclass, p_name name, p_lo text, p_hi text
)
returns void language plpgsql as $$
declare v_lo_lit text; v_hi_lit text;
begin
  v_lo_lit := pgpm._encode(p_cfg.control_kind, p_lo);
  v_hi_lit := pgpm._encode(p_cfg.control_kind, p_hi);
  execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                 p_nsp, p_name, p_nsp, p_rel, v_lo_lit, v_hi_lit);
  perform pgpm._own_like_parent(format('%I.%I', p_nsp, p_rel)::regclass,
                                format('%I.%I', p_nsp, p_name)::regclass);
  insert into pgpm.part (parent_table, child_name, lo, hi)
    values (format('%I.%I', p_nsp, p_rel)::regclass, p_name, p_lo, p_hi) on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'obtain', p_lo, p_hi, 'plain');
end;
$$;

-- #280: obtain became a PROCEDURE because _create_partition commits. Drop the old function first.
-- #288: obtain is a plain FUNCTION again. It became a procedure for #280 only so _create_partition could
-- commit between the phases of its exclusion-constraint dance; with the DEFAULT gone there is no dance,
-- nothing to prove empty, and nothing to recover from. The advisory lock, the stranded-constraint sweep
-- and the deferral reporting all went with it.
drop procedure if exists pgpm.obtain(regclass, int, boolean);

-- obtain(): build the empty forward partitions ahead of the frontier.
--
-- This is now pgpm's ONLY defence against a write with nowhere to go, since there is no DEFAULT to catch
-- one. config.obtain x partition_step is therefore both the slack for maintenance falling behind and a
-- hard ceiling on how far ahead an application may write. The default is 30 steps for that reason.
create or replace function pgpm.obtain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name;
  v_frontier text; v_lo text; v_hi text; v_name name;
  v_made int := 0; k int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

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

    perform pgpm._create_partition(cfg, v_nsp, v_rel, null, v_name, v_lo, v_hi);
    v_made := v_made + 1;
  end loop;
  return v_made;
end;
$$;

-- drain_step / drain_all removed with the DEFAULT partition (#288). With a complete forward grid there
-- is nothing for a row to land in except a real partition, so there is nothing to evacuate.

-- #288: both drain routines are gone; drop whichever form a prior version left behind.
drop function  if exists pgpm.drain_all(regclass, int, boolean);
drop procedure if exists pgpm.drain_all(regclass, int, boolean, int);
drop function  if exists pgpm.drain_step(regclass, int, boolean);



-- the retention horizon on the native grid: the grid-floored boundary at/below which a partition's
-- whole range has aged out. null = no retention policy. Shared by retain() (what to drop now) and
-- status() (retain_backlog: what is eligible but not yet dropped).
create or replace function pgpm._retain_boundary(cfg pgpm.config)
returns text language plpgsql as $$
begin
  if cfg.retain is null then return null; end if;
  if cfg.control_kind = 'id' then
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            (pgpm._frontier_native(cfg.parent_table)::numeric - cfg.retain::numeric)::text);
  else
    return pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                            (now() - cfg.retain::interval)::text);
  end if;
end;
$$;

-- ==================== retiring a REFERENCED partition (issue #268) ====================
--
-- `p_incoming_fks => 'preserve'` and a `retain` policy were both supported and both documented, and
-- the combination never reclaimed anything: every retain() failed on the oldest eligible partition and
-- returned 0, forever, while the write block was already installed. Frozen AND unreclaimable.
--
-- `DROP TABLE <partition>` is refused on a pure CATALOG dependency. An FK against a partitioned parent
-- puts one pg_constraint row per referenced partition ON the referencing table, and the refusal is
-- data-INDEPENDENT: identical whether one row references, zero rows reference, or the referencing
-- table is empty. DETACH is the only phase that consults data, and a successful one severs the
-- per-partition constraint, after which the DROP is completely unguarded. So: detach, then drop. The
-- referencing table's own FK survives and still enforces.
--
-- The detach must be CONCURRENT. Measured on PG 17.10, 8M-row referencing table:
--
--   ALTER TABLE ... DETACH PARTITION               AccessExclusiveLock on the MANAGED PARENT, ~1.5 s;
--                                                  a concurrent read of the parent dies with 55P03
--   ALTER TABLE ... DETACH PARTITION CONCURRENTLY  ShareUpdateExclusiveLock; the parent stays readable
--                                                  and writable throughout
--
-- Plain DETACH would make retention block the table pgpm exists to keep online, for a duration set by
-- the size of a table pgpm does not own. That is exactly the shape the project's acceptance rule
-- forbids. And PostgreSQL refuses to run the concurrent form from any of the contexts pgpm has:
--
--   ERROR:  ALTER TABLE ... DETACH CONCURRENTLY cannot be executed from a function
--
-- not from a procedure that has already committed, not from a DO block, and not via dynamic EXECUTE:
-- it is a check on execution CONTEXT, and pgpm is pure SQL. So pgpm DISPATCHES it. pg_cron is already
-- pgpm's one runtime dependency, and a cron job's command runs as a top-level statement in its own
-- session, where the statement is legal. retire() repoints a single standing job at the specific
-- detach and completes the DROP on a later tick.
--
-- ONE STANDING JOB, rewritten in place, not one job per retirement: pg_cron has no one-shot schedule,
-- so a per-retirement job would keep firing after it succeeded and log `is not a partition` failures
-- until something unscheduled it. pgpm.schedule() creates `pgpm_detach` idle (`select 1`); retire()
-- points it at a detach when it needs one and returns it to idle once the drop lands. At most one
-- detach is in flight, which retention's existing retain_batch pacing already assumes.
--
-- What this costs, stated plainly: retirement of a REFERENCED partition is asynchronous, spanning at
-- least one cron tick, and it requires pgpm.schedule() to have been run. Retention was already
-- eventual, so this lengthens a delay rather than introducing one. Writes to the REFERENCING table are
-- blocked for O(that table) by the detach's ShareLock, once per retirement -- readers of it, and the
-- managed parent entirely, are unaffected. That part is irreducible: it is PostgreSQL proving the FK
-- still holds. An index on the referencing FK column does NOT reduce it (measured: 1368 ms without,
-- 1634 ms with).

-- _crossing_keys: the control-column values inside [p_lo, p_hi) that some incoming foreign key still
-- references -- the rows where the operator's two promises, the FK and the retention horizon,
-- genuinely contradict.
--
-- Identification runs FIRST and unconditionally, rather than attempting the detach and catching its
-- error, because a FAILING detach is only cheap when the referencing FK column happens to be indexed.
-- Measured, 8M-row referencing table: identifying costs 0.7 ms indexed and 141.9 ms unindexed, against
-- a failing DETACH's 1.9 ms indexed but 1176 ms unindexed -- a near-full scan under ShareLock paid
-- purely to discover the operation cannot proceed, with the locks already taken. Pre-identifying also
-- reports every crossing key at once, where PostgreSQL names one at a time.
create or replace function pgpm._crossing_keys(p_parent regclass, p_lo text, p_hi text)
returns text[] language plpgsql as $$
declare
  cfg pgpm.config; r record;
  v_ctrl_attnum smallint; v_refcol name; v_pos int;
  v_lo_lit text; v_hi_lit text; v_vals text[] := '{}'; v_more text[];
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;

  select a.attnum into v_ctrl_attnum from pg_attribute a
   where a.attrelid = p_parent and a.attname = cfg.control_column and not a.attisdropped;

  v_lo_lit := pgpm._encode(cfg.control_kind, p_lo);
  v_hi_lit := pgpm._encode(cfg.control_kind, p_hi);

  -- conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets
  -- one pg_constraint row per partition of the referenced side, so an unfiltered scan would visit the
  -- same foreign key once per partition.
  for r in
    select c.conname, c.conrelid::regclass as referencing, c.conkey, c.confkey
      from pg_constraint c
     where c.confrelid = p_parent and c.contype = 'f' and c.conparentid = 0
  loop
    -- Which referencing column maps to the CONTROL column? A foreign key can only reference a unique
    -- constraint, and every unique constraint on a partitioned table must include the partition key,
    -- so this position always exists in pgpm's shape. Say so loudly if it ever does not, rather than
    -- silently reporting no crossing and going on to a detach that will refuse.
    v_pos := array_position(r.confkey, v_ctrl_attnum);
    if v_pos is null then
      raise exception 'pg_partition_magician: foreign key % on % references % without its control column %, so pgpm cannot tell which rows cross the retention horizon',
        r.conname, r.referencing, p_parent, cfg.control_column;
    end if;
    select a.attname into v_refcol from pg_attribute a
     where a.attrelid = r.referencing and a.attnum = (r.conkey)[v_pos];

    -- A plain range predicate: a row whose key falls in [lo, hi) references a row in THIS partition,
    -- by the definition of range partitioning, whatever else the key carries.
    execute format(
      'select coalesce(array_agg(distinct %I::text), ''{}''::text[]) from %s where %I >= %L and %I < %L',
      v_refcol, r.referencing::text, v_refcol, v_lo_lit, v_refcol, v_hi_lit)
      into v_more;
    v_vals := v_vals || v_more;
  end loop;
  return v_vals;
end;
$$;

-- _dispatch_detach: point the standing `pgpm_detach` job at this partition's concurrent detach.
-- Returns null on success, or the REASON it could not dispatch -- pg_cron not installed, pgpm.schedule()
-- never run, no privilege on cron.job. All three are configuration problems the operator has to see and
-- fix, so the reason is carried back verbatim to be logged rather than flattened into a bare false.
--
-- Dynamic EXECUTE because the `cron` schema is only resolved at call time, so this file still installs
-- cleanly where pg_cron is not enabled. Both relations are schema-qualified in the command: the cron
-- job runs in its own session, with its own search_path.
create or replace function pgpm._dispatch_detach(p_parent regclass, p_child name)
returns text language plpgsql as $$
declare v_nsp name; v_rel name; v_cmd text; v_n int;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_cmd := format('alter table %I.%I detach partition %I.%I concurrently', v_nsp, v_rel, v_nsp, p_child);
  begin
    execute format(
      'select count(*)::int from (select cron.alter_job(jobid, command => %L) from cron.job'
      || ' where jobname = ''pgpm_detach'' and database = current_database()) s', v_cmd)
      into v_n;
  exception when others then
    return left(sqlerrm, 160);
  end;
  if v_n > 0 then return null; end if;
  return 'no pgpm_detach cron job in this database; run pgpm.schedule()';
end;
$$;

-- the reverse: put the standing job back to idle once a retirement completes, so it is not left
-- re-running a detach that has already happened (which logs `is not a partition` every tick).
create or replace function pgpm._idle_detach_job()
returns void language plpgsql as $$
begin
  execute 'select cron.alter_job(jobid, command => ''select 1'') from cron.job'
       || ' where jobname = ''pgpm_detach'' and database = current_database()';
exception when others then
  null;   -- no pg_cron, or no such job: there is nothing to quiesce
end;
$$;

-- retire(): the sanctioned single-partition drop (issue #195) -- retain()'s per-partition body,
-- public and claim-guarded, so an external assistant (e.g. an archive-then-drop scanner) or several
-- cooperating ones can drive retirement themselves through the same protocol retain() uses: claim,
-- ensure write-blocked, gate on archive coverage, DROP, catalog + log. It never widens what
-- retention may drop: the child's whole range must sit at/below the retention horizon, so a caller
-- only picks WHICH eligible partition and WHEN. Returns true iff this call dropped the partition.
--
-- Drop precondition, as of issue #238: past the retention horizon (as before), write-blocked, and
-- pgpm._archive_fully_covered. Write-blocking is ENSURED here (pgpm._install_write_block is
-- idempotent), not merely asserted: retire() is called by more than one path -- retain()'s own loop,
-- an external assistant, pgpm_archive's self-driving sweep -- and only maintain() is guaranteed to
-- have run _enforce_write_blocks first. Asserting (raising) instead would make retire() fail for
-- every caller that reaches an eligible partition some other way, which defeats the entire point of
-- retire() being independently callable. Archive coverage is different: a child mid-chunked-archive
-- is a normal, expected, RETRYABLE state, not a failure -- retire() just returns false, the same way
-- it already does for a concurrently-claimed partition, so retain()'s batch loop skips it this cycle
-- without logging anything.
--
-- The pgpm.hook pre_drop registry this used to consult (hooks ran in registration order
-- immediately before the DROP) is gone entirely as of issue #240 -- archive coverage via
-- config.archive_fn is the only gate a drop precondition has now.
--
-- Returns false, without side effects, when the pgpm.part row is absent (already retired by another
-- actor) or claimed by a concurrent transaction: FOR UPDATE SKIP LOCKED (issue #188) gives each
-- partition exactly one owner at a time. The claim is taken OUTSIDE the DROP's own subtransaction,
-- so an unexpected drop failure (retain_drop_fail, logged, retried on a later call) keeps the row
-- claimed until the caller's transaction ends.
create or replace function pgpm.retire(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_boundary text; r record;
  v_referenced boolean; v_still_attached boolean;
  v_cross text[]; v_coltype text; v_lo_lit text; v_hi_lit text; v_deleted int; v_reason text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then
    raise exception 'pg_partition_magician: % has no retention policy (config.retain is null); retire() drops only what retention allows', p_parent;
  end if;

  -- the claim: one owner per partition at a time
  select p.lo, p.hi, p.attached, p.retiring_at into r
    from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child
     for update skip locked;
  if not found then return false; end if;
  if not r.attached then
    raise exception 'pg_partition_magician: %.% is not an attached partition (an in-flight regrain child is not retirable)', p_parent, p_child;
  end if;

  v_boundary := pgpm._retain_boundary(cfg);
  if pgpm._native_gt(cfg.control_kind, r.hi, v_boundary) then
    raise exception 'pg_partition_magician: % is not entirely past the retention horizon (hi %, horizon %)', p_child, r.hi, v_boundary;
  end if;

  perform pgpm._install_write_block(p_parent, p_child);

  if not pgpm._archive_fully_covered(p_parent, p_child) then
    return false;
  end if;

  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  -- Is anything pointing at this parent at all (issue #268)? Without an incoming FK the bare DROP
  -- below works and costs nothing, so the overwhelmingly common path stays byte-identical: no marker,
  -- no cron round trip, no waiting a tick. Gating here also confines the concurrent detach, and the
  -- reaper hazard that comes with it, to the tables that actually need them.
  v_referenced := exists (select 1 from pg_constraint
                           where confrelid = p_parent and contype = 'f' and conparentid = 0);

  if v_referenced then
    v_still_attached := exists (
      select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
       where i.inhparent = p_parent and c.relname = p_child);

    if v_still_attached then
      -- ONE DETACH IN FLIGHT AT A TIME, database-wide. There is a single standing cron job, so a
      -- second dispatch would overwrite the first and silently abandon it -- leaving a partition
      -- marked retiring_at that nothing is detaching. retain()'s batch loop walks every eligible
      -- partition, and maintain_all walks every managed parent, so this is the common case, not an
      -- exotic race: without this guard one retain() call marks the whole backlog and only the last
      -- one is real. A retirement stops holding the job the moment its partition is detached, so this
      -- yields rather than blocks: the next tick takes the next partition. Silent and retryable, like
      -- the archive-coverage gate above.
      -- Yield only to a STRICTLY OLDER in-flight retirement, on a total order. "Yield to any other" is
      -- the obvious formulation and it deadlocks: two concurrent retire() calls can both pass the check
      -- and both mark, after which each sees the other in flight and neither ever proceeds again. With a
      -- total order the oldest marker always wins, so there is always exactly one partition able to make
      -- progress and the loser simply retries. An unmarked candidate sorts last (`infinity`), so a fresh
      -- retirement always yields to one already under way.
      if exists (
        select 1 from pgpm.part p
         where p.retiring_at is not null
           and not (p.parent_table = p_parent and p.child_name = p_child)
           and (p.retiring_at, p.parent_table::text, p.child_name)
             < (coalesce(r.retiring_at, 'infinity'::timestamptz), p_parent::text, p_child)
           and exists (select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
                        where i.inhparent = p.parent_table and c.relname = p.child_name))
      then
        return false;
      end if;

      -- THE CROSSING. A live row genuinely referencing a doomed row is the one case where retention
      -- and referential integrity contradict, and pgpm has NO policy decision to make here: the
      -- operator already chose, per constraint, in the FK's ON DELETE clause. DELETE lets PostgreSQL
      -- apply whatever was declared, with no branching -- CASCADE clears the referencing rows, SET
      -- NULL and SET DEFAULT sever them in place, NO ACTION and RESTRICT refuse and therefore block
      -- retention exactly as specified, surfacing the operator's own error rather than a pgpm one.
      -- (DETACH cannot be left to do this: it is structural, so no action triggers fire, and it
      -- unilaterally refuses for every constraint -- correct by coincidence for NO ACTION, an override
      -- of an explicit instruction for CASCADE.)
      v_cross := pgpm._crossing_keys(p_parent, r.lo, r.hi);
      if coalesce(array_length(v_cross, 1), 0) > 0 then
        select format_type(a.atttypid, a.atttypmod) into v_coltype
          from pg_attribute a where a.attrelid = p_parent and a.attname = cfg.control_column;
        v_lo_lit := pgpm._encode(cfg.control_kind, r.lo);
        v_hi_lit := pgpm._encode(cfg.control_kind, r.hi);
        begin
          -- The write block installed above is a BEFORE ROW trigger on this child covering DELETE
          -- too, so it would refuse this. Lift it for the delete and put it straight back: DDL is
          -- transactional and retire() does not commit, so no other session ever observes the child
          -- unblocked. Disabling triggers wholesale is NOT an option -- that would switch off the RI
          -- triggers whose actions are the entire point of doing this as a DELETE.
          perform pgpm._remove_write_block(p_parent, p_child);
          execute format(
            'delete from %s where %I >= %L and %I < %L and %I = any (%L::text[]::%s[])',
            p_parent::text, cfg.control_column, v_lo_lit, cfg.control_column, v_hi_lit,
            cfg.control_column, v_cross, v_coltype);
          get diagnostics v_deleted = row_count;
          perform pgpm._install_write_block(p_parent, p_child);
          -- Logged loudly and separately: this fires referential actions on tables pgpm was not
          -- handed, which is the one thing retirement does beyond its own partition.
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'retain_crossing', r.lo, r.hi,
                    format('%s referenced key(s), %s row(s) deleted to honour the declared ON DELETE',
                           array_length(v_cross, 1), v_deleted));
        exception when others then
          insert into pgpm.log (parent_table, action, lo, hi, method)
            values (p_parent, 'fail_retain_crossing', r.lo, r.hi, left(sqlerrm, 200));
          return false;
        end;
      end if;

      -- Mark, then dispatch, in one transaction: the marker and the job's new command become visible
      -- together, so there is never a detach in flight that recovery cannot attribute.
      -- coalesce, NOT an unconditional stamp: retiring_at is when this retirement BEGAN, and a retry
      -- must not refresh it. Re-stamping makes the winner perpetually the newest marker, so it stops
      -- being the winner, and the total order above degenerates into no order at all -- two partitions
      -- then dispatch in the same tick and one clobbers the other's job.
      update pgpm.part set retiring_at = coalesce(retiring_at, clock_timestamp())
       where parent_table = p_parent and child_name = p_child;

      v_reason := pgpm._dispatch_detach(p_parent, p_child);
      if v_reason is null then
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'retain_detach', r.lo, r.hi,
                  'concurrent detach dispatched; the drop completes on a later tick');
      else
        insert into pgpm.log (parent_table, action, lo, hi, method)
          values (p_parent, 'fail_retain_detach', r.lo, r.hi,
                  format('%s -- a referenced partition cannot be retired without it', v_reason));
      end if;
      return false;   -- retirement is under way, not done
    end if;

    -- Detached but not yet dropped. Complete it only if this was pgpm's retirement: an operator's own
    -- interrupted DETACH CONCURRENTLY gets finalized by _detach_reap and then left alone, rather than
    -- having pgpm drop a table it was never asked to drop.
    if r.retiring_at is null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'fail_retain_drop', r.lo, r.hi,
                'detached from the parent by something other than retirement; not dropping it');
      return false;
    end if;
  end if;

  begin
    execute format('drop table %I.%I', v_nsp, p_child);
    delete from pgpm.part where parent_table = p_parent and child_name = p_child;
    insert into pgpm.log (parent_table, action, lo, hi) values (p_parent, 'retain_drop', r.lo, r.hi);
    if v_referenced then perform pgpm._idle_detach_job(); end if;
    return true;
  exception when others then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'fail_retain_drop', r.lo, r.hi, left(sqlerrm, 200));
    return false;
  end;
end;
$$;

create or replace function pgpm.retain(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; v_ncast text; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retain is null then return 0; end if;

  v_boundary := pgpm._retain_boundary(cfg);
  v_ncast := pgpm._native_type(cfg.control_kind);

  -- retire() carries the per-partition protocol (claim, write-block, archive-coverage gate, drop,
  -- bookkeeping -- see there); this loop only picks the eligible set, oldest first, capped by
  -- retain_batch (issue #189; 'limit all' when null). A retire() that returns false (archive
  -- coverage not yet complete -- a normal, retryable state, not a failure -- or claimed/retired by a
  -- concurrent assistant) still consumed its batch slot: the cap bounds ATTEMPTS, not successes.
  for r in execute format(
    'select child_name from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s order by lo::%s limit %s',
    p_parent::text, v_ncast, v_boundary, v_ncast, v_ncast, coalesce(cfg.retain_batch::text, 'all'))
  loop
    if pgpm.retire(p_parent, r.child_name) then v_dropped := v_dropped + 1; end if;
  end loop;
  return v_dropped;
end;
$$;

-- write-block on retain-eligibility (issue #235). A
-- partition past _retain_boundary() is drop-eligible, and for however long it takes chunked
-- archiving to finish covering it (or forever, for a table with no archive strategy at all), it
-- should not accept writes either -- a backdated write into that span, including into a range some
-- earlier archive chunk already covered, would silently diverge the archive from what is live. Two
-- alternatives were ruled out empirically, not on paper: REVOKEing INSERT/UPDATE/DELETE on the
-- child does nothing, because a parent-routed write is checked against the PARENT's ACL, never the
-- child's; and a lock spanning the whole (unbounded, chunked) archiving window defeats the reason
-- chunking exists. A BEFORE ROW trigger on the specific child is checked regardless of routing,
-- can't be bypassed by an owner or superuser the way a privilege check can, and is torn down for
-- free by the eventual DROP TABLE.
create or replace function pgpm._write_block_raise() returns trigger
language plpgsql as $$
begin
  raise exception 'pg_partition_magician: % is past its retention boundary and is no longer writable', tg_table_name;
end;
$$;

-- idempotent: a no-op if the child is already blocked, so a repeat _enforce_write_blocks tick (every
-- maintain() call revisits every attached child) never raises a duplicate-trigger error.
create or replace function pgpm._install_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name; v_child regclass;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_child := format('%I.%I', v_nsp, p_child)::regclass;
  if exists (select 1 from pg_trigger where tgrelid = v_child and tgname = 'pgpm_write_block') then
    return;
  end if;
  execute format(
    'create trigger pgpm_write_block before insert or update or delete on %I.%I'
    || ' for each row execute function pgpm._write_block_raise()', v_nsp, p_child);
end;
$$;

-- the reverse: an operator loosening config.retain can make a previously-eligible partition
-- ineligible again, so this needs to run just as often as _install_write_block. drop ... if exists
-- makes it just as idempotent on a child that was never blocked.
create or replace function pgpm._remove_write_block(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('drop trigger if exists pgpm_write_block on %I.%I', v_nsp, p_child);
end;
$$;

-- reconciles every attached child's write-block state against current eligibility in one pass,
-- reusing the exact _retain_boundary() retire() itself checks so "eligible to write-block" and
-- "eligible to drop" can never disagree. A table with no retention policy (config.retain null) has
-- no boundary at all, so nothing is ever eligible and nothing is ever blocked.
create or replace function pgpm._enforce_write_blocks(p_parent regclass)
returns void language plpgsql as $$
declare
  cfg pgpm.config; v_boundary text; r record; v_eligible boolean;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_boundary := pgpm._retain_boundary(cfg);

  for r in select child_name, hi from pgpm.part where parent_table = p_parent and attached
  loop
    v_eligible := v_boundary is not null and not pgpm._native_gt(cfg.control_kind, r.hi, v_boundary);
    if v_eligible then
      perform pgpm._install_write_block(p_parent, r.child_name);
    else
      perform pgpm._remove_write_block(p_parent, r.child_name);
    end if;
  end loop;
end;
$$;

-- true iff the write-block trigger is actually installed on this child right now (checked directly
-- against pg_trigger, not re-derived from the boundary formula) -- shared by _archive_step (issue
-- #237, only ever archives an already-blocked child) and retire() (issue #238) below.
create or replace function pgpm._is_write_blocked(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  return exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where t.tgname = 'pgpm_write_block' and c.relname = p_child and c.relnamespace = v_nsp::regnamespace
  );
end;
$$;

-- ===================== pluggable archive strategy (issue #236) =====================
-- One archive strategy per managed table (config.archive_fn), superseding the old generic
-- pgpm.hook pre_drop registry (removed entirely, issue #240) -- archiving before a drop was its
-- only real use. pgpm._archive_step (below) drives this every maintain() tick, and retire()'s drop
-- precondition gates on pgpm._archive_fully_covered.

-- archive_fn's return shape: how much of a requested [lo, hi) a single call durably archived.
-- covered_hi is the native-grid value up to which [lo, ...) is now durably archived by THIS call --
-- may be less than hi, since a real strategy is expected to be resumable (called again next tick to
-- make further bounded progress, not to finish the whole range at once). rows_archived is how many
-- rows this call actually archived; null when nothing was actually archived (the 'none' strategy,
-- or a strategy that made no progress this tick). s3_key/etag are optional identifiers a transport
-- strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet, issue #239) can
-- report back for the ledger row; null for a strategy with nothing object-store-shaped to name (the
-- 'none' strategy, pgpm._archive_noop, a user-authored strategy that doesn't use S3). No CREATE OR
-- REPLACE TYPE exists in PostgreSQL, so guard creation the same way the rest of this file guards
-- idempotent DDL.
do $$ begin
  if not exists (
    select 1 from pg_type where typname = 'archive_result' and typnamespace = 'pgpm'::regnamespace
  ) then
    create type pgpm.archive_result as (covered_hi text, rows_archived bigint, s3_key text, etag text);
  end if;
end $$;

-- the trivial built-in strategy: exists only to exercise real dispatch (a real regprocedure call,
-- not a null-strategy special case) in tests. Always reports the whole requested range archived
-- immediately -- functionally what a 'none'-strategy table already gets from
-- _run_archive_strategy's null handling below, just reached via a real archive_fn call.
create or replace function pgpm._archive_noop(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_rows bigint; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  execute format('select count(*) from %I.%I where %I >= %L and %I < %L',
                 v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, p_lo),
                 cfg.control_column, pgpm._encode(cfg.control_kind, p_hi))
    into v_rows;
  v_result.covered_hi := p_hi;
  v_result.rows_archived := v_rows;
  return v_result;
end;
$$;

-- the dispatch stub: looks up config.archive_fn and calls it. A null archive_fn (strategy 'none')
-- never actually archives anything, so the requested range is trivially "already fully covered" --
-- there is nothing to protect against a drop.
create or replace function pgpm._run_archive_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare cfg pgpm.config; v_result pgpm.archive_result;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then
    v_result.covered_hi := p_hi;
    v_result.rows_archived := null;
    return v_result;
  end if;
  -- select * from fn(...), not select fn(...): the latter returns the composite as ONE column,
  -- which EXECUTE ... INTO a named-composite variable maps positionally (1 source column against
  -- pgpm.archive_result's 2 fields) rather than assigning the whole value -- covered_hi would end
  -- up holding the composite's own text form and rows_archived would stay null. Calling it as a
  -- FROM-item expands its fields into real output columns first.
  execute format('select * from %s($1,$2,$3,$4)', (cfg.archive_fn::oid::regproc)::text)
    into v_result using p_parent, p_child, p_lo, p_hi;
  return v_result;
end;
$$;

-- ============= byte-budget chunked archiving on the archive_fn contract (issue #237) =============
-- Ports archive._next_range_byte_budget/archive.archive_range/archive.ledger (#213, #221) -- the
-- mechanism that makes archiving a large partition safe without one giant transaction -- onto the
-- archive_fn contract, unchanged in intent. The one real adaptation: the original picked a range
-- across the WHOLE table, bounded by the frontier and the retention horizon directly, because
-- nothing else gated eligibility yet. Here that gating is already done per child by the write-block
-- trigger (#235) -- a child only becomes a candidate once _enforce_write_blocks has actually
-- installed it -- so the chunk picker only ever needs to work within ONE already-eligible child's
-- own [lo, hi), never across partition boundaries. archive.ledger/archive.archive_range/archive.tick
-- in pgpm_archive are untouched and keep working exactly as before; they are deleted only once this
-- path is proven out (#240).

-- successor to archive.ledger, same shape (parent_table, lo, hi, child_name nullable, s3_key, etag,
-- rows_archived, archived_at), primary key (parent_table, lo) since a chunk always belongs to
-- exactly one child and one parent's chunks never overlap. s3_key/etag come straight from
-- pgpm.archive_result (issue #239 widened the contract to carry them) -- populated for a real
-- transport strategy (e.g. pgpm_archive's pgpm.archive_to_s3_ndjson/archive_to_s3_parquet), still
-- null for a strategy with nothing object-store-shaped to name (pgpm._archive_noop, the 'none'
-- strategy). rows_archived is nullable (unlike the original's not null): the contract explicitly
-- allows a strategy to report no progress on a given call.
create table if not exists pgpm.archive_ledger (
  parent_table  regclass    not null,
  lo            text        not null,
  hi            text        not null,
  child_name    name,
  s3_key        text,
  etag          text,
  rows_archived bigint,
  archived_at   timestamptz not null default now(),
  primary key (parent_table, lo)
);
create index if not exists archive_ledger_parent_child_hi_idx on pgpm.archive_ledger (parent_table, child_name, hi desc);

-- picks the next chunk to archive within ONE child: resumes from wherever pgpm.archive_ledger's
-- coverage of THIS child left off (or the child's own lo, on the first call), estimates how many
-- rows fit config.archive_byte_budget via a sampled average row width (config.archive_probe_sample
-- rows), then extends to the next distinct control value past the probed boundary so a run of ties
-- never splits across two chunks -- identical reasoning to the original, just scoped to the child's
-- own table instead of the parent. Returns no rows once the child is fully covered.
create or replace function pgpm._next_archive_chunk(p_parent regclass, p_child name)
returns table(lo text, hi text)
language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_ncast text;
  v_child_lo text; v_child_hi text; v_lo text;
  v_avg numeric; v_batch int; v_batch_count int; v_probe_hi_col text; v_probe_hi text;
  v_next_distinct_col text; v_stop text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select p.lo, p.hi into v_child_lo, v_child_hi from pgpm.part p
   where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is stored as text; a plain max() would compare lexicographically ('91' > '1000'), not
  -- numerically/temporally -- cast to the native type first, the same fix archive._file_watermark
  -- already needed for this exact reason.
  execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 v_ncast, p_parent::text, p_child)
    into v_lo;
  v_lo := coalesce(v_lo, v_child_lo);

  if not pgpm._native_gt(cfg.control_kind, v_child_hi, v_lo) then
    return;   -- already fully covered
  end if;

  execute format(
    'select avg(pg_column_size(t.*))::numeric from (select * from %I.%I t where t.%I >= %L order by t.%I limit %s) t',
    v_nsp, p_child, cfg.control_column, pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, cfg.archive_probe_sample)
    into v_avg;
  if coalesce(v_avg, 0) <= 0 then
    -- no rows remain in [v_lo, child_hi) for this child. Unlike the original (which read ahead of a
    -- still-moving frontier, where "nothing yet" could mean "not yet arrived"), this child is
    -- already write-blocked and frozen -- nothing will EVER land here again, so the rest of its
    -- range is trivially covered with zero rows archived.
    lo := v_lo; hi := v_child_hi;
    return next;
    return;
  end if;
  v_batch := greatest(1, floor(cfg.archive_byte_budget::numeric / v_avg))::int;

  execute format(
    'select count(*), max(%I)::text from (select %I from %I.%I t where t.%I >= %L order by t.%I limit %s) s',
    cfg.control_column, cfg.control_column, v_nsp, p_child, cfg.control_column,
    pgpm._encode(cfg.control_kind, v_lo), cfg.control_column, v_batch)
    into v_batch_count, v_probe_hi_col;

  if v_batch_count < v_batch then
    v_stop := v_child_hi;   -- the byte budget reaches past this child's own live end
  else
    v_probe_hi := pgpm._decode(cfg.control_kind, v_probe_hi_col);
    -- extend to the next distinct value past the boundary, so hi never splits a run of ties (a
    -- child's own CHECK bounds every row here to < v_child_hi already, so this can never overshoot it)
    execute format('select min(%I)::text from %I.%I t where t.%I > %L',
                   cfg.control_column, v_nsp, p_child, cfg.control_column, v_probe_hi_col)
      into v_next_distinct_col;
    v_stop := case when v_next_distinct_col is null then v_child_hi
                   else pgpm._decode(cfg.control_kind, v_next_distinct_col) end;
  end if;

  if not pgpm._native_gt(cfg.control_kind, v_stop, v_lo) then
    return;   -- no progress possible this call
  end if;

  lo := v_lo; hi := v_stop;
  return next;
end;
$$;

-- true once pgpm.archive_ledger's recorded ranges for this child reach its own hi, or the strategy
-- is 'none' (nothing to protect against a drop). Chunks for a given child are gapless and
-- monotonically forward by construction (_next_archive_chunk always resumes exactly where the last
-- one left off), so the ledger's own max(hi) reaching the child's hi is exactly "the union covers
-- [lo, hi)" -- the same watermark reasoning archive._file_watermark already relied on.
create or replace function pgpm._archive_fully_covered(p_parent regclass, p_child name)
returns boolean language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_child_hi text; v_watermark text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return true; end if;

  select p.hi into v_child_hi from pgpm.part p where p.parent_table = p_parent and p.child_name = p_child;
  if not found then raise exception 'pg_partition_magician: %.% is not a tracked partition', p_parent, p_child; end if;

  -- hi is text; cast to the native type before max()'ing, same reasoning (and the same fix) as
  -- _next_archive_chunk above -- a plain max() would compare lexicographically.
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select max(hi::%s)::text from pgpm.archive_ledger where parent_table = %L::regclass and child_name = %L',
                 v_ncast, p_parent::text, p_child)
    into v_watermark;

  return v_watermark is not null and not pgpm._native_gt(cfg.control_kind, v_child_hi, v_watermark);
end;
$$;

-- one maintenance tick's worth of chunked archiving: for every attached child that ALREADY has the
-- write-block trigger installed (checked directly against pg_trigger, not re-derived from the
-- boundary formula -- this is what keeps archiving from ever running ahead of write-blocking) and is
-- not yet fully covered, pick its next chunk, run the configured strategy, and record progress.
-- Returns how many chunks were recorded this call. A 'none' strategy (archive_fn null) has nothing
-- to do -- every child is already "covered" per _archive_fully_covered above.
create or replace function pgpm._archive_step(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_ncast text; r record; v_range record; v_result pgpm.archive_result; v_count int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.archive_fn is null then return 0; end if;

  v_ncast := pgpm._native_type(cfg.control_kind);

  -- oldest first, matching retain()'s own convention -- archiving history in age order, though each
  -- child's progress is independent of the others' either way.
  for r in execute format(
    'select p.child_name from pgpm.part p where p.parent_table = %L::regclass and p.attached order by p.lo::%s',
    p_parent::text, v_ncast)
  loop
    if not pgpm._is_write_blocked(p_parent, r.child_name) then continue; end if;
    if pgpm._archive_fully_covered(p_parent, r.child_name) then continue; end if;

    select * into v_range from pgpm._next_archive_chunk(p_parent, r.child_name);
    if not found then continue; end if;

    v_result := pgpm._run_archive_strategy(p_parent, r.child_name, v_range.lo, v_range.hi);

    insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, etag, rows_archived)
    values (p_parent, v_range.lo, v_result.covered_hi, r.child_name, v_result.s3_key, v_result.etag, v_result.rows_archived);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ============================== regrain ==============================

-- regrain splits a FROZEN coarse child (the monolith, or a coarser child from a prior pass) into finer
-- children, by COPYING the rows into standalone children in budget-sized microbatches, then in ONE atomic
-- step detaching the coarse source, attaching the fine children, and DROPping the source. It never deletes
-- a row out of the source -- the source stays whole and ATTACHED until the swap, so every row remains
-- visible through the parent the entire time. The product has no dead tuples (the fine children only ever
-- receive inserts) and no vacuum (the source's space is reclaimed by the DROP, not by DELETE). Because the
-- rows are never moved through an unattached child, regrain NEVER opens the snapshot() read gap, and the
-- multi-tick COPY needs no FK leash (the drain's delete-and-move is the one that carries that) -- REDESIGN.md
-- sections 9 and 10. The one exception is the swap's DETACH itself: Postgres refuses to detach a partition
-- whose rows are still referenced by an incoming FK (the keys leave the parent between detach and the
-- re-attach of the copies, which it will not look past), so the swap transiently drops the incoming FK(s)
-- and re-adds them within its ONE atomic transaction -- invisible to other sessions, so RI is never visibly
-- off, unlike the move-model's whole-regrain suspension. Retention-aware: a sub-range entirely below the
-- retention horizon is NOT copied (it is discarded with the source at the DROP), so retention costs no delete.
--
-- The work is a series of resumable microbatches (regrain_step). Because the source is frozen and is never
-- deleted from, it cannot drive progress the way the drain's shrinking DEFAULT does, so progress is tracked
-- explicitly by config.regrain_cursor: the native-grid lo of the sub-range currently being copied. A child is
-- built to completion (one budget batch at a time, resumed from its own high-water mark) before the cursor
-- advances to the next sub-range; when the cursor reaches the coarse hi every sub-range is copied (or aged
-- and skipped) and the swap runs. regrain() loops regrain_step in ONE transaction (atomic, gap-free) -- the
-- operator's "do it now". maintain() calls regrain_step ONCE per tick when auto-regrain is on (REDESIGN.md sec
-- 12), feathering the copy under the live workload across ticks. The cross-tick path leaves copies in
-- not-yet-attached children between ticks, but since the source still holds those rows, the parent's count
-- is never short and snapshot() must NOT union those copies (it would double-count).

-- ===================== regrain change capture and reconcile (issue #267) =====================
--
-- regrain COPIES, and its copy is resume-safe three ways: a `>= max(dest.ctl)` high-water bound, a
-- `not exists` anti-join on the reused key, and a cursor that advances past a completed sub-range and
-- never returns. NONE of the three is a reconcile -- the copy only ever ADDS rows and only ever moves
-- FORWARD -- and the swap then drops the source, so without this apparatus the copy silently becomes the
-- authority for everything that changed after it ran: a committed INSERT is destroyed, a committed DELETE
-- comes back, a committed UPDATE reverts.
--
-- "Frozen" (regrain_step's precondition) does NOT mean immutable: it only says the write frontier has
-- moved past the child. A backdated INSERT or an explicit low id routes straight into it, a
-- cross-partition UPDATE can move a row in, and DELETE/payload-UPDATE of history never involved the
-- frontier at all. So capture must be correct however much arrives, not merely for a well-behaved
-- append-only workload.
--
-- Shape: the delta table and its trigger function are PER PARENT and persistent (named from the parent,
-- which is stable -- naming from the child would break, since #266's fix renames the source mid-flight);
-- only the trigger on the source child is per regrain. Lifecycle therefore reduces to rows, not
-- relations, and an abandoned regrain leaks a trigger the janitor removes rather than an orphan table.

create or replace function pgpm._regrain_capture_names(
  p_parent regclass, out nsp name, out delta name, out fn name
) returns record language plpgsql stable as $$
declare v_rel name;
begin
  select n.nspname, c.relname into nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  delta := left(v_rel || '_pgpm_regrain_delta', 63)::name;
  fn    := left(v_rel || '_pgpm_regrain_capture', 63)::name;
end;
$$;

-- Install capture for a regrain of p_child: mint the per-parent delta table and trigger function if this
-- parent has never regrained, clear any residue from a previous regrain, and put the trigger on the source
-- child. CREATE TRIGGER takes SHARE ROW EXCLUSIVE, which conflicts with ROW EXCLUSIVE, so in-flight DML
-- blocks the install and DML afterwards sees the trigger: once this commits nothing can have slipped past
-- uncaptured. That lock is why this is its own tick -- sharing a transaction with a copy batch would hold
-- it across the batch instead of for an O(1) statement.
create or replace function pgpm._regrain_capture_install(p_parent regclass, p_child name)
returns void language plpgsql as $$
declare
  v_nsp name; v_delta name; v_fn name; v_keyidx oid; v_keycols text; v_newvals text; v_oldvals text;
  v_bad text;
begin
  select nsp, delta, fn into v_nsp, v_delta, v_fn from pgpm._regrain_capture_names(p_parent);

  select coalesce(
           (select i.indexrelid from pg_index i where i.indrelid = p_parent and i.indisprimary limit 1),
           (select con.conindid from pg_constraint con join pg_index i on i.indexrelid = con.conindid
             where con.conrelid = p_parent and con.contype = 'u'
               and i.indpred is null and i.indexprs is null limit 1))
    into v_keyidx;
  if v_keyidx is null then
    raise exception 'pg_partition_magician: cannot capture regrain changes on % -- no primary key or unique constraint', p_parent;
  end if;

  -- A NULL key component can never be matched by the row-constructor reconcile below, so its change would
  -- be silently lost -- the exact failure this apparatus exists to prevent. PK columns are NOT NULL, but a
  -- reused UNIQUE key may legitimately permit nulls, so refuse rather than lose the change.
  select string_agg(quote_ident(a.attname), ', ') into v_bad
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx and not a.attnotnull;
  if v_bad is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- its reused key has nullable column(s) (%), and a NULL key component cannot be reconciled, so a concurrent change to such a row would be lost. Add NOT NULL to those columns, then re-run.',
      p_parent, v_bad;
  end if;

  select string_agg(quote_ident(a.attname), ', ' order by k.ord),
         string_agg('new.' || quote_ident(a.attname), ', ' order by k.ord),
         string_agg('old.' || quote_ident(a.attname), ', ' order by k.ord)
    into v_keycols, v_newvals, v_oldvals
    from pg_index i
    cross join lateral unnest(i.indkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indexrelid = v_keyidx;

  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then
    execute format('create table %I.%I as select %s from %s with no data', v_nsp, v_delta, v_keycols, p_parent::text);
    -- monotonic ordering column so a reconcile pass can batch by a pgpm_seq watermark: a batch processes
    -- and deletes rows at or below the watermark, and anything arriving mid-batch lands higher for the next
    -- pass. Excluded by name wherever key columns are introspected.
    execute format('alter table %I.%I add column pgpm_seq bigint generated always as identity', v_nsp, v_delta);
    execute format('create index on %I.%I (pgpm_seq)', v_nsp, v_delta);
  end if;
  execute format('truncate %I.%I', v_nsp, v_delta);   -- residue from an earlier regrain is not ours

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
    v_nsp, v_fn,
    v_nsp, v_delta, v_keycols, v_oldvals,
    v_nsp, v_delta, v_keycols, v_oldvals, v_newvals,
    v_nsp, v_delta, v_keycols, v_newvals);

  execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, p_child);
  execute format('create trigger pgpm_regrain_capture after insert or update or delete on %I.%I for each row execute function %I.%I()',
                 v_nsp, p_child, v_nsp, v_fn);
end;
$$;

-- true iff p_child currently carries the capture trigger
create or replace function pgpm._regrain_capture_active(p_parent regclass, p_child name)
returns boolean language plpgsql stable as $$
declare v_nsp name;
begin
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  return exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                  where t.tgname = 'pgpm_regrain_capture' and c.relname = p_child
                    and c.relnamespace = v_nsp::regnamespace);
end;
$$;

-- how many captured changes are still outstanding (used by the swap gate and by status)
create or replace function pgpm._regrain_delta_count(p_parent regclass)
returns bigint language plpgsql stable as $$
declare v_nsp name; v_delta name; v_n bigint;
begin
  select nsp, delta into v_nsp, v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  execute format('select count(*) from %I.%I', v_nsp, v_delta) into v_n;
  return v_n;
end;
$$;

-- Discard captured keys whose control has left this child's range: a cross-partition UPDATE moved the row
-- out, and its OLD-key entry (still in range) already covers the removal here. Such an entry can never
-- apply AND can never become eligible, so leaving it forever would wedge the swap gate, which counts every
-- delta row.
--
-- Deliberately NOT part of the per-tick reconcile. The predicate is a negated range, which no index serves,
-- so running it per tick meant a seq scan of the whole delta on every tick -- O(delta) work per tick and
-- O(delta^2 / batch) overall, which is the same shape #272 removed from the watermark query and which the
-- bench/regrain_perf.sh guard caught still present here. It is only the swap gate that these rows can
-- affect, so it runs once, immediately before that gate.
create or replace function pgpm._regrain_delta_purge(p_parent regclass, p_lo text, p_hi text)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_delta name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return; end if;
  execute format('delete from %I.%I where not (%3$s >= %4$L and %3$s < %5$L)',
                 v_nsp, v_delta, quote_ident(cfg.control_column),
                 pgpm._encode(cfg.control_kind, p_lo), pgpm._encode(cfg.control_kind, p_hi));
end;
$$;

-- Reconcile up to p_batch captured keys, returning how many were consumed.
--
-- THE CONTRACT: for each captured key the SOURCE is the authority, not the recorded change. Delete the
-- key's row from its fine child, then reinsert the source's current row for that key if it still exists.
-- One rule covers all three defects, and critically it covers keys the copy has NEVER SEEN, which the
-- INSERT case needs and which any replay-the-change design would miss. It is idempotent and
-- order-independent per key, which is what makes it safe under READ COMMITTED: a synchronous
-- apply-the-change trigger is not, because it can fire against a copy that does not hold the row yet and
-- then be overwritten by a copy statement running from an earlier snapshot.
--
-- ELIGIBILITY: only keys whose control value lies strictly BELOW the cursor, i.e. in a sub-range the copy
-- has already finished. Two reasons. The copy can still reach anything at or above the cursor by itself,
-- so reconciling there is wasted work; and writing into the sub-range currently being copied would move
-- max(dest.ctl), which the copy uses as its resume point, making it skip the rows in between. At the swap
-- the cursor is at hi, so everything becomes eligible.
create or replace function pgpm._regrain_reconcile(
  p_parent regclass, p_child name, p_lo text, p_hi text, p_step text, p_cursor text, p_batch int
) returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_delta name; v_ncast text; v_keycols text; v_dkey text;
  v_skey text; v_cols text; v_wm bigint; v_elig text; v_ctl text; v_sub_name name; v_n int := 0; r record;
  v_lo_lit text; v_hi_lit text; v_cur_lit text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is null then return 0; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);

  select string_agg(quote_ident(attname), ', ' order by attnum),
         '(' || string_agg('d.' || quote_ident(attname), ', ' order by attnum) || ')',
         '(' || string_agg('s.' || quote_ident(attname), ', ' order by attnum) || ')'
    into v_keycols, v_dkey, v_skey
    from pg_attribute where attrelid = format('%I.%I', v_nsp, v_delta)::regclass
      and attnum > 0 and not attisdropped and attname <> 'pgpm_seq';
  -- generated columns are omitted from the reinsert: they recompute, they are never inserted into
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped and attgenerated = '';

  -- The delta is populated by a trigger and nothing analyzes it, so on its first ticks it carries no usable
  -- row estimate and the planner misplans one of the statements below into a seq scan of the WHOLE delta.
  -- Measured: 1 seq scan reading every delta row per tick without stats, 0 with them. Same failure #164
  -- fixed for freshly minted children ("it sits at reltuples = -1 until autovacuum, and anything touching
  -- it misplans"), so it gets the same treatment. One-time: once analyzed the estimate stays good enough
  -- as the delta grows (47k estimated against 50k actual still planned correctly).
  if (select coalesce(reltuples, -1) from pg_class where oid = format('%I.%I', v_nsp, v_delta)::regclass) <= 0 then
    perform pgpm._analyze(format('%I.%I', v_nsp, v_delta)::regclass);
  end if;

  -- Compare in ENCODED space -- the control column's own type, against _encode'd boundaries -- exactly as
  -- the copy does with its v_lo_lit/v_hi_lit. Decoding per row instead (pgpm._decode(...)::native) is a
  -- function call the planner cannot index, which silently turned every reconcile tick into a seq scan of
  -- the WHOLE delta rather than an indexed read of one batch: measured 272 ms to pick 5000 rows out of a
  -- 300k delta, against 1.0 ms once the pgpm_seq index is usable. That made the tick scale with the delta
  -- instead of with the budget, so draining a large delta cost O(delta^2 / batch). uuidv7 compares
  -- correctly this way because a UUIDv7 sorts by its embedded timestamp, which is why the copy can do it too.
  v_ctl     := quote_ident(cfg.control_column);
  v_lo_lit  := pgpm._encode(cfg.control_kind, p_lo);
  v_hi_lit  := pgpm._encode(cfg.control_kind, p_hi);
  v_cur_lit := pgpm._encode(cfg.control_kind, p_cursor);

  -- eligible: in this child's range AND behind the cursor
  v_elig := format('%1$s >= %2$L and %1$s < %3$L and %1$s < %4$L', v_ctl, v_lo_lit, v_hi_lit, v_cur_lit);

  execute format('select max(pgpm_seq) from (select pgpm_seq from %I.%I where %s order by pgpm_seq limit %s) t',
                 v_nsp, v_delta, v_elig, greatest(p_batch, 1)) into v_wm;
  if v_wm is null then return 0; end if;

  -- one pair of set-based statements per distinct fine child touched, not per key
  for r in execute format(
    'select distinct pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, %I::text)) as sub_lo
       from %I.%I where pgpm_seq <= %s and %s',
    cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column,
    v_nsp, v_delta, v_wm, v_elig)
  loop
    v_sub_name := pgpm._part_name(v_rel, cfg.control_kind, p_step, r.sub_lo,
                                  pgpm._grid_next(cfg.control_kind, p_step, r.sub_lo));
    -- No fine child means the sub-range was skipped as aged (regrain_aged): it is never materialized and
    -- its rows go with the source, so there is nothing to reconcile into. Counted, not silent.
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'regrain_reconcile_aged', r.sub_lo, null, v_sub_name);
      continue;
    end if;
    execute format(
      'delete from %I.%I d where %s in (select %s from %I.%I k where k.pgpm_seq <= %s and %s
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, k.%I::text)) = %L)',
      v_nsp, v_sub_name, v_dkey, v_keycols, v_nsp, v_delta, v_wm, v_elig,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column, r.sub_lo);
    execute format(
      'insert into %I.%I (%s) select %s from %I.%I s where %s in (select %s from %I.%I k where k.pgpm_seq <= %s and %s
          and pgpm._grid_floor(%L, %L, %L, pgpm._decode(%L, k.%I::text)) = %L)',
      v_nsp, v_sub_name, v_cols, v_cols, v_nsp, p_child, v_skey, v_keycols, v_nsp, v_delta, v_wm, v_elig,
      cfg.control_kind, p_step, cfg.partition_anchor, cfg.control_kind, cfg.control_column, r.sub_lo);
  end loop;

  execute format('delete from %I.%I where pgpm_seq <= %s and %s', v_nsp, v_delta, v_wm, v_elig);
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into pgpm.log (parent_table, action, lo, hi, rows)
      values (p_parent, 'regrain_reconcile', p_lo, p_hi, v_n);
  end if;
  return v_n;
end;
$$;

-- The janitor (#267). Change capture is installed per regrain and normally dies with the source at the
-- swap, but a regrain can be abandoned silently: the operator sets regrain_to to null mid-flight, or drives
-- a manual regrain of child A while auto-regrain is working child B and the two clobber the shared cursor.
-- A left-behind trigger taxes every write to that child and fills a delta nobody reads.
--
-- The child that legitimately carries capture is derivable with no extra state: the attached child whose
-- range covers regrain_cursor, and none at all when the cursor is null. `hi` is inclusive here because a
-- regrain awaiting its swap sits with the cursor exactly at hi. Deliberately conservative: it only tears
-- down capture it can prove is orphaned, never one that might still be live.
--
-- Mirrors _enforce_write_blocks: reconcile every child's state against current policy, once per tick.
create or replace function pgpm._enforce_regrain_capture(p_parent regclass)
returns void language plpgsql as $$
declare cfg pgpm.config; v_nsp name; v_keep boolean; r record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then return; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for r in select child_name, lo, hi from pgpm.part where parent_table = p_parent
  loop
    if not pgpm._regrain_capture_active(p_parent, r.child_name) then continue; end if;
    v_keep := cfg.regrain_cursor is not null
          and not pgpm._native_gt(cfg.control_kind, r.lo, cfg.regrain_cursor)       -- lo <= cursor
          and not pgpm._native_gt(cfg.control_kind, cfg.regrain_cursor, r.hi);      -- cursor <= hi
    if not v_keep then
      execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, r.child_name);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        values (p_parent, 'regrain_capture_orphan', r.lo, r.hi, r.child_name);
    end if;
  end loop;
end;
$$;

-- Stop an in-flight regrain and reclaim what it has built. Returns the number of in-flight fine children
-- dropped. The janitor above handles the silent abandonments; this is the operator's deliberate escape.
--
-- The copies MUST be dropped, not kept. Keeping them looks thriftier, but a later regrain would resume from
-- copies made before this cancel and therefore never reconciled, which is exactly the bug #267 closes. The
-- source still holds every row, so discarding them costs only the work, never data.
create or replace function pgpm.regrain_cancel(p_parent regclass)
returns int language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_delta name; v_dropped int := 0; r record;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;

  for r in select child_name from pgpm.part where parent_table = p_parent loop
    execute format('drop trigger if exists pgpm_regrain_capture on %I.%I', v_nsp, r.child_name);
  end loop;

  select delta into v_delta from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta);
  end if;

  for r in select child_name from pgpm.part where parent_table = p_parent and not attached loop
    execute format('drop table if exists %I.%I', v_nsp, r.child_name);
    delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
    v_dropped := v_dropped + 1;
  end loop;

  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, rows) values (p_parent, 'regrain_cancel', v_dropped);
  return v_dropped;
end;
$$;

-- one resumable microbatch of regrain work on coarse child p_child toward target step p_target_step.
-- Returns: 'copied:N' (copied N rows into the current fine child), 'swapped:K' (cursor reached hi -> detached
-- the source, attached K fine children, dropped it: regrain done), or a soft no-progress status ('active' =
-- not frozen yet, 'default_dirty' = a stray sits in the range, 'nosubdiv' = the step does not subdivide).
create or replace function pgpm.regrain_step(
  p_parent regclass, p_child name, p_target_step text default null, p_batch int default null
) returns text language plpgsql as $$
declare
  cfg pgpm.config; v_nsp name; v_rel name; v_child regclass; v_cols text; v_ncast text; v_pkjoin text; v_keyidx oid;
  v_lo text; v_hi text; v_step text; v_frontier text; v_floor text; v_has boolean;
  v_retain_boundary text; v_batch int; v_reltuples real; v_avg numeric;
  v_cursor text; v_grid_lo text; v_sub_lo text; v_sub_hi text; v_sub_name name;
  v_lo_lit text; v_hi_lit text; v_moved bigint := 0; v_aged boolean; v_made int := 0; v_fk int := 0; r record;
  v_child_name name; v_src_name name; v_rec int; v_delta_n bigint; v_i int; v_delta_name name; v_busy name;
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
  v_child      := format('%I.%I', v_nsp, p_child)::regclass;
  v_child_name := p_child;   -- may be renamed below (#266); v_child is an oid and follows it for free
  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped
      and attgenerated = '';   -- omit generated columns: they recompute on insert, never inserted into
  -- the reused-key equijoin (d.<key> = s.<key>, every key column): the copy is an anti-join against it, so
  -- a resumed batch never re-copies a row already in the child even when the control column is non-unique.
  -- The key is whatever transmute reused: a PRIMARY KEY, or (relaxed key contract) a UNIQUE constraint.
  -- A truly KEYLESS monolith has no key to identify rows by, so a resumable copy cannot dedup -- regrain is
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
  -- ONE regrain per parent at a time (#267). This is a correctness guard, not tidiness: both
  -- config.regrain_cursor and the change-capture delta are per parent, so a second regrain starting on a
  -- different child would reset the first one's cursor AND truncate its delta at prepare, silently
  -- discarding captured changes the first regrain had not applied yet. That is the same class of loss this
  -- apparatus exists to prevent. The cursor thrash alone predates capture (each child resets the cursor
  -- into its own range), so this refusal closes a pre-existing hazard too.
  --
  -- Placed BEFORE the #266 rename below, so a refused regrain mutates nothing at all -- not even the
  -- transitional rename of the child it was never going to split. After the soft statuses above, so a
  -- not-yet-frozen child still answers 'active' rather than raising.
  select p.child_name into v_busy from pgpm.part p
   where p.parent_table = p_parent and p.child_name <> v_child_name
     and pgpm._regrain_capture_active(p_parent, p.child_name)
   limit 1;
  if v_busy is not null then
    raise exception 'pg_partition_magician: cannot regrain % -- a regrain of % is already in flight on this parent, and pgpm runs one regrain per parent (config.regrain_cursor and the change-capture delta are both per parent). Let it finish, or abandon it with pgpm.regrain_cancel(%), then re-run.',
      v_child_name, v_busy, p_parent;
  end if;

  -- ...and the source must not be named as its own first fine sub-range (issue #266). _part_name gives a
  -- one-step range the bare _p<lo> and a wider one the explicit _p<lo>_to_<hi>, and the note above it says
  -- why: the wide form exists "so it can never collide with the fine child at its low edge". But "wider"
  -- was judged on the child's OWN grid. A child exactly one step wide is not wide there, so it kept _p<lo>
  -- -- and regrain then reinterprets it on a FINER grid, where its own first sub-range renders _p<lo> too.
  -- That was silent data loss, not a cosmetic clash: the "does the destination exist yet?" check below
  -- found the SOURCE, took it for an already-created destination, the anti-join copy moved nothing,
  -- v_moved < v_batch advanced the cursor as though the sub-range were done, and the swap's DROP TABLE took
  -- those rows with it.
  --
  -- Finish the design instead of refusing: rename the source to its own name as rendered on the TARGET
  -- grid. `nosubdiv` above already established v_hi > grid_next(v_step, v_lo), so on that grid the source
  -- IS wider than one step and always takes the explicit _to_ form, which no one-step sub-range can equal.
  -- This is safe precisely because of the other half of that note: the name is a human-facing LABEL and
  -- pgpm.part holds the authoritative bounds. v_child is an oid, so every later statement here follows the
  -- table with no re-resolution. Derived from v_lo rather than the cursor, so it also fires for a regrain
  -- resumed past its first sub-range instead of reaching the swap with the collision still ahead of it.
  v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_lo);
  v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
  v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo);
  if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
  if pgpm._part_name(v_rel, cfg.control_kind, v_step, v_sub_lo, v_sub_hi) = v_child_name then
    v_src_name := pgpm._part_name(v_rel, cfg.control_kind, v_step, v_lo, v_hi);
    if to_regclass(format('%I.%I', v_nsp, v_src_name)) is not null then
      raise exception 'pg_partition_magician: cannot regrain % at target step % -- splitting it needs the transitional name %, which is already taken by another relation. Drop or rename that relation, then re-run.',
        v_child_name, v_step, v_src_name;
    end if;
    execute format('alter table %s rename to %I', v_child::text, v_src_name);
    update pgpm.part set child_name = v_src_name
     where parent_table = p_parent and child_name = v_child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_rename', v_lo, v_hi, v_child_name || ' -> ' || v_src_name);
    v_child_name := v_src_name;
  end if;
  -- The 'default_dirty' gate is gone with the DEFAULT (#288). It guarded against a stray sitting in the
  -- range, which would make a fine-child ATTACH fail at the swap; with a complete forward grid there is
  -- nowhere for a stray to sit except a real partition of the range being regrained.

  -- #267: change capture must be installed AND COMMITTED before any copy reads the source, or every change
  -- made during the first batch is lost. Its own tick, so CREATE TRIGGER's SHARE ROW EXCLUSIVE is an O(1)
  -- hold rather than one spanning a copy batch. Setting the cursor here too keeps the janitor's invariant
  -- ("cursor null => no child carries the trigger") true from the first tick, so it cannot tear down a
  -- regrain that is one tick old.
  if not pgpm._regrain_capture_active(p_parent, v_child_name) then
    -- A cursor already set with no capture installed means copies exist that were made WITHOUT capture:
    -- an interrupted regrain from before this apparatus, or one the janitor cleaned up mid-flight. Those
    -- copies are unreconciled, so resuming from them would reintroduce exactly this bug. Discard and
    -- restart, which is cheap: the source still holds every row.
    if cfg.regrain_cursor is not null then
      for r in execute format(
        'select child_name from pgpm.part where parent_table = %L::regclass and not attached'
        || ' and lo::%s >= %L::%s and hi::%s <= %L::%s',
        p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast)
      loop
        execute format('drop table if exists %I.%I', v_nsp, r.child_name);
        delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
        v_made := v_made + 1;
      end loop;
      insert into pgpm.log (parent_table, action, lo, hi, rows, method)
        values (p_parent, 'regrain_restart', v_lo, v_hi, v_made, 'copies predate change capture');
    end if;
    perform pgpm._regrain_capture_install(p_parent, v_child_name);
    update pgpm.config set regrain_cursor = v_lo where parent_table = p_parent;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (p_parent, 'regrain_prepare', v_lo, v_hi, v_child_name);
    return 'prepared';
  end if;

  -- retention horizon (matches retain() and the drain's retain_reclaim, issue #91)
  if cfg.retain is not null then
    if cfg.control_kind = 'id'
      then v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (v_frontier::numeric - cfg.retain::numeric)::text);
      else v_retain_boundary := pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor,
                                  (now() - cfg.retain::interval)::text);
    end if;
  end if;

  -- budget (rows per microbatch): regrain_batch, capped by regrain_max_blocks via the coarse child's stats
  v_batch := coalesce(p_batch, cfg.regrain_batch, 5000);
  if cfg.regrain_max_blocks is not null then
    select c.reltuples into v_reltuples from pg_class c where c.oid = v_child;
    if coalesce(v_reltuples, 0) > 0 then v_avg := pg_table_size(v_child)::numeric / v_reltuples;
    else execute format('select avg(pg_column_size(t))::numeric from (select * from %s limit 1000) t', v_child::text) into v_avg;
    end if;
    if coalesce(v_avg, 0) > 0 then
      v_batch := least(v_batch, greatest(1, floor(cfg.regrain_max_blocks::numeric * 8192 / v_avg))::int);
    end if;
  end if;
  v_batch := greatest(1, v_batch);   -- a copied:0 batch must advance the cursor (0 < batch), never stall

  -- progress cursor: the lo of the sub-range currently being copied. null (fresh) or stale (out of this
  -- child's [lo,hi)) -> start at the coarse lo. The cursor only ever advances, one grid sub-range at a time.
  v_cursor := cfg.regrain_cursor;
  if v_cursor is null
     or pgpm._native_gt(cfg.control_kind, v_lo, v_cursor)        -- cursor < coarse lo
     or pgpm._native_gt(cfg.control_kind, v_cursor, v_hi) then   -- cursor > coarse hi
    v_cursor := v_lo;
  end if;

  -- #267: reconcile captured changes before copying more. Only sub-ranges the copy has already finished
  -- are eligible (see _regrain_reconcile), so this never disturbs max(dest.ctl) in the sub-range being
  -- copied. Bounded by the same budget as the copy, and it takes the tick when there is work, so a burst
  -- of DML paces itself instead of landing in the swap.
  v_rec := pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_cursor, v_batch);
  if v_rec > 0 then return 'reconciled:' || v_rec; end if;

  -- Advance over any aged (below-horizon) sub-ranges without copying them: they would be dropped by retain()
  -- the instant they became partitions, so they are simply discarded with the source at the swap (never
  -- materialized, and never deleted out of the source either). Aged ranges are the lowest in control order, a
  -- contiguous prefix, so this loop only runs at the bottom of the child. One regrain_aged per skipped range.
  --
  -- ONLY when there is nothing to archive (#278). That "they would be dropped by retain() anyway" reasoning
  -- was written before #238 gave retire a coverage gate, and stopped being true then: with archive_fn set,
  -- retire refuses to drop a partition until archiving has fully covered it, so discarding these rows
  -- destroys exactly what the gate is holding back, unarchived. Measured: 2000 rows gone, archive ledger
  -- empty.
  --
  -- So with archive_fn set the sub-range is materialized like any other, and the EXISTING pipeline takes it
  -- from there in the right order: _enforce_write_blocks blocks it (its whole range is below the horizon
  -- now that it is a partition), _archive_step archives it, retire drops it once covered. That also closes
  -- the write-block asymmetry, since a late backdated write lands in a partition that gets archived.
  --
  -- Not "wait for coverage before skipping", which cannot work: a PARTIALLY aged child straddles the
  -- horizon, so it is never write-blocked and therefore never archived, and the regrain would wait forever
  -- for coverage nothing produces.
  --
  -- The cost when archive_fn is set is copying rows that are about to be dropped. They have to be read to
  -- archive them regardless, so it is one extra write of doomed data, and only on tables that archive.
  loop
    exit when not pgpm._native_gt(cfg.control_kind, v_hi, v_cursor);   -- cursor >= hi: nothing left to copy
    v_grid_lo := pgpm._grid_floor(cfg.control_kind, v_step, cfg.partition_anchor, v_cursor);
    v_sub_lo  := case when pgpm._native_gt(cfg.control_kind, v_lo, v_grid_lo) then v_lo else v_grid_lo end;
    v_sub_hi  := pgpm._grid_next(cfg.control_kind, v_step, v_grid_lo);
    if pgpm._native_gt(cfg.control_kind, v_sub_hi, v_hi) then v_sub_hi := v_hi; end if;
    v_aged := v_retain_boundary is not null
              and cfg.archive_fn is null                                  -- #278: see above
              and not pgpm._native_gt(cfg.control_kind, v_sub_hi, v_retain_boundary);
    exit when not v_aged;                                             -- found a sub-range to copy
    insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_aged', v_sub_lo, v_sub_hi, 0);
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
    -- invariant (#266): the rename above makes this unreachable. Assert it anyway -- when it was false the
    -- failure was silent row destruction, so a future change to _part_name must break loudly here.
    if v_sub_name = v_child_name then
      raise exception 'pg_partition_magician: internal error regraining % -- sub-range [%, %) resolves to the source child itself; refusing rather than copying into the table about to be dropped.',
        v_child_name, v_sub_lo, v_sub_hi;
    end if;
    if to_regclass(format('%I.%I', v_nsp, v_sub_name)) is null then
      execute format('create table %I.%I (like %I.%I including defaults including generated including storage including indexes including constraints excluding identity)',
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
      insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'regrain_copy', v_sub_lo, v_sub_hi, v_moved);
    end if;
    if v_moved < v_batch then
      v_cursor := v_sub_hi;                                          -- sub-range fully copied: advance
      -- the fine child holds all its rows now and is still standalone (it is attached later, at the swap):
      -- ANALYZE it here, off the swap's exclusive-lock window, so the swap and any query that hits it after
      -- see real stats, not reltuples = -1 (#164).
      perform pgpm._own_like_parent(p_parent, format('%I.%I', v_nsp, v_sub_name)::regclass);   -- #277
      perform pgpm._analyze(format('%I.%I', v_nsp, v_sub_name)::regclass);
    end if;
    update pgpm.config set regrain_cursor = v_cursor where parent_table = p_parent;
    return 'copied:' || v_moved;
  end if;

  -- #267: do not ENTER the swap carrying a backlog. The residual reconcile below runs inside the swap
  -- transaction, so it must be small; the gate is what keeps it so. Checked before the DETACH, because once
  -- that holds ACCESS EXCLUSIVE no further writes can arrive and the residual is only what was in flight at
  -- that instant. Deliberately no forcing: if writes outpace reconciliation the regrain stalls here
  -- indefinitely, which is correct -- the source stays attached, reads are unaffected, the table is
  -- consistent, and status() shows it. Forcing would put an unbounded reconcile under the lock.
  perform pgpm._regrain_delta_purge(p_parent, v_lo, v_hi);   -- junk cannot be allowed to wedge the gate
  v_delta_n := pgpm._regrain_delta_count(p_parent);
  if v_delta_n > v_batch then return 'reconciling:' || v_delta_n; end if;

  -- cursor reached hi: every sub-range is copied (or aged and skipped). Swap atomically -- detach the source,
  -- attach every not-yet-attached fine child within its range (metadata-only via each child's validated
  -- CHECK), drop the source whole (no DELETE; the aged rows that were never copied go with it).
  --
  -- DETACH is refused while an incoming FK still references the source's rows (they leave the parent between
  -- detach and the re-attach of the copies). Drop the incoming FK(s) for the swap and re-add them, all inside
  -- THIS one transaction, so no other session ever observes RI off. force=true since the copy did not
  -- suspend; v_fk=0 means there was no live preserve-managed FK to drop -- either the table has none, or
  -- the conversion's drop has not been restored yet -- so leave the re-add to restore_incoming_fks.
  v_fk := pgpm.suspend_incoming_fks(p_parent, true);
  execute format('alter table %s detach partition %s', p_parent::text, v_child::text);
  -- #267: the correctness backstop. The DETACH above holds ACCESS EXCLUSIVE on the source, so no further
  -- writes can arrive and this terminates. The cursor is at hi, so every captured key is now eligible.
  -- Bounded by the gate; the loop only covers what landed between the gate and the DETACH.
  for v_i in 1 .. 100 loop
    exit when pgpm._regrain_reconcile(p_parent, v_child_name, v_lo, v_hi, v_step, v_hi, greatest(v_batch, 1000)) = 0;
  end loop;
  for r in execute format(
    'select child_name, lo, hi from pgpm.part where parent_table = %L::regclass and not attached and lo::%s >= %L::%s and hi::%s <= %L::%s order by lo::%s',
    p_parent::text, v_ncast, v_lo, v_ncast, v_ncast, v_hi, v_ncast, v_ncast)
  loop
    execute format('alter table %s attach partition %I.%I for values from (%L) to (%L)',
                   p_parent::text, v_nsp, r.child_name,
                   pgpm._encode(cfg.control_kind, r.lo), pgpm._encode(cfg.control_kind, r.hi));
    execute format('alter table %I.%I drop constraint %I', v_nsp, r.child_name, (r.child_name || '_ck'));
    update pgpm.part set attached = true where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'regrain_attach', r.lo, r.hi, 'check_skip');
    v_made := v_made + 1;
  end loop;
  delete from pgpm.part where parent_table = p_parent and child_name = v_child_name;   -- not p_child: #266 may have renamed it
  execute format('drop table %s', v_child::text);
  -- the capture trigger went with the dropped source (#267); clear the delta so the next regrain of this
  -- parent starts from an empty one and status() does not report a phantom backlog.
  select delta into v_delta_name from pgpm._regrain_capture_names(p_parent);
  if to_regclass(format('%I.%I', v_nsp, v_delta_name)) is not null then
    execute format('truncate %I.%I', v_nsp, v_delta_name);
  end if;
  -- re-add the FK(s) this swap dropped, against the new parent (the copies now hold every key). Only if WE
  -- dropped them (v_fk > 0): v_fk = 0 means there was nothing live to drop, so there is nothing here to put
  -- back -- restore_incoming_fks owns any FK still suspended from the conversion.
  if v_fk > 0 then perform pgpm.restore_incoming_fks(p_parent); end if;
  update pgpm.config set regrain_cursor = null where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, rows, method) values (p_parent, 'regrain', v_lo, v_hi, v_made, 'copy_swap_drop');
  return 'swapped:' || v_made;
end;
$$;

-- regrain(): the synchronous "do it now" driver -- loops regrain_step in ONE transaction (atomic, gap-free)
-- until the coarse child is fully split, and returns the number of fine children created. Soft no-progress
-- statuses become a hard error here (the operator gets a clear refusal); maintain() instead just skips.
create or replace function pgpm.regrain(p_parent regclass, p_child name, p_target_step text default null)
returns int language plpgsql as $$
declare v_status text; v_iter int := 0; v_child name := p_child; v_next name; v_lo text;
begin
  -- regrain_step may rename the source child on its first pass (#266: a child exactly one step wide is
  -- renamed to its coarse-form name on the target grid so its own first sub-range can take _p<lo>). Follow
  -- it by lo, which never changes, and re-resolve the name each iteration -- otherwise every iteration after
  -- the first would look up a name that no longer exists. Only the source is attached at that lo during the
  -- copy phase (fine children stay attached = false until the swap), so the lookup is unambiguous.
  select lo into v_lo from pgpm.part
   where parent_table = p_parent and child_name = p_child and attached;
  loop
    v_status := pgpm.regrain_step(p_parent, v_child, p_target_step, null);
    if v_status like 'swapped:%' then return split_part(v_status, ':', 2)::int; end if;
    if v_status in ('active', 'default_dirty', 'nosubdiv', 'nokey', 'idle') then
      raise exception 'pg_partition_magician: cannot regrain % -- %', p_child,
        case v_status
          when 'active' then 'it is still active (not frozen); wait until the frontier passes its upper bound'
          when 'default_dirty' then 'the DEFAULT holds rows inside its range; drain them first'
          when 'nosubdiv' then 'the target step does not subdivide its range'
          when 'nokey' then 'it has no primary key or unique constraint, so a resumable copy cannot identify rows; regrain is unavailable for keyless tables (the coarse monolith remains a valid, queryable state)'
          else 'nothing to regrain' end;
    end if;
    v_iter := v_iter + 1;
    if v_iter > 10000000 then raise exception 'pg_partition_magician: regrain safety limit'; end if;
    if v_lo is not null then
      select p.child_name into v_next from pgpm.part p
       where p.parent_table = p_parent and p.lo = v_lo and p.attached;
      v_child := coalesce(v_next, v_child);
    end if;
  end loop;
end;
$$;

-- regrain_history(): convenience -- regrain the oldest coarse child (the monolith: the smallest-lo attached
-- partition) to p_target_step (default: the configured partition_step). Hierarchical regraining is just
-- repeated regrain() calls with chosen steps.
create or replace function pgpm.regrain_history(p_parent regclass, p_target_step text default null)
returns int language plpgsql as $$
declare cfg pgpm.config; v_ncast text; v_mon name;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  v_ncast := pgpm._native_type(cfg.control_kind);
  execute format('select child_name from pgpm.part where parent_table = %L::regclass and attached order by lo::%s asc limit 1',
                 p_parent::text, v_ncast) into v_mon;
  if v_mon is null then raise exception 'pg_partition_magician: % has no partitions to regrain', p_parent; end if;
  return pgpm.regrain(p_parent, v_mon, p_target_step);
end;
$$;

-- ============================== transmute ==============================

-- #275 turned these from FUNCTIONs into PROCEDUREs. CREATE OR REPLACE cannot change that, so the old
-- forms have to go first; an existing install upgrades cleanly through this.
drop function if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean);
drop function  if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean);
-- #288 dropped p_keep_default and p_drain_adaptive and renamed p_drain_batch, so the previous PROCEDURE
-- forms must go as well or an upgrade leaves two overloads and every call becomes ambiguous.
drop procedure if exists pgpm.transmute(regclass, name, interval, int, interval, boolean, int, timestamptz, boolean, text, boolean, boolean, int);
drop procedure if exists pgpm.transmute(regclass, name, bigint, int, bigint, boolean, int, bigint, boolean, text, boolean, int);
drop procedure if exists pgpm._transmute(regclass, name, text, text, text, int, text, boolean, int, boolean, text, boolean, boolean, int);

create or replace procedure pgpm._transmute(
  p_parent regclass, p_control name, p_control_kind text,
  p_step text, p_anchor text, p_obtain int, p_retain text,
  p_regrain_batch int, p_paused boolean, p_incoming_fks text,
  p_force_uuidv7 boolean default false, p_bound_headroom int default 0
)
language plpgsql as $$
declare
  v_nsp name; v_rel name; v_default name; v_parent regclass;
  v_lo_prev text; v_hi_prev text; v_resumed boolean := false;
  v_typname text; v_oldpk text[]; v_pkcols text[]; v_idcols name[]; v_pkname name; v_col name;
  v_idx_names text[]; v_idx_defs text[]; v_ctl_attnum int; v_uniq_bad text; v_old name; v_new name; v_pdef text; j int;
  v_add_pk boolean := false; v_add_uniq boolean := false; v_reuse_idx oid; v_reuse_conname name;
  v_uq_cols text[]; v_bare_uq text;
  v_fk record; v_dropped jsonb := '[]'::jsonb; v_e jsonb; v_fk_eligible boolean;
  v_uchk_n bigint; v_uchk_frac numeric;
  v_idmax bigint[]; v_m bigint; v_i int; v_idnext bigint[]; v_seq text; v_n bigint;
  v_monolith name; v_monreg regclass;
  v_frontier_native text; v_min_raw text; v_max_raw text; v_min_native text; v_lo_native text; v_hi_native text;
  -- #277: everything CREATE TABLE ... LIKE does NOT carry, captured before the rename and replayed onto
  -- the new parent inside the cutover transaction.
  v_owner name; v_acl aclitem[]; v_rls boolean; v_rls_force boolean;
  v_comment text; v_colcom record; v_pol record; v_trg record; v_bad_trg text;
  v_trgdefs text[] := '{}'; v_grant text; v_g record;
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
      -- also capture the column's current sequence position, so the reseed below never moves the sequence
      -- BACKWARD past ids it has already handed out (a gap above max from rollbacks, caching, or deleted
      -- high rows). Captured now, while the original sequence still exists (step 3 drops it on the monolith).
      v_seq := pg_get_serial_sequence(p_parent::text, v_col);
      v_n := null;
      if v_seq is not null then
        execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_n;
      end if;
      v_idnext := array_append(v_idnext, v_n);
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
        -- (regrain is unavailable for a keyless monolith -- it has no key to dedup a resumed copy -- but
        -- the coarse monolith is a correct, queryable permanent state; see regrain_step.)
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

  -- Refuse the one trigger shape a partitioned table cannot host (#277). Measured on PG 17.10: this is
  -- the ONLY refusal needed. Constraint triggers, statement triggers, WHEN clauses, UPDATE OF, and even
  -- statement triggers WITH transition tables all transfer to a partitioned parent; only a FOR EACH ROW
  -- trigger with a transition table is rejected. Refusing beats converting and dropping it, which is the
  -- silent-loss failure this whole issue is about.
  select string_agg(tgname, ', ' order by tgname) into v_bad_trg
    from pg_trigger
   where tgrelid = p_parent and not tgisinternal
     and (tgoldtable is not null or tgnewtable is not null)
     and (tgtype & 1) = 1;   -- TRIGGER_TYPE_ROW
  if v_bad_trg is not null then
    raise exception 'pg_partition_magician: cannot transmute % -- the row trigger(s) (%) use a transition table (REFERENCING OLD/NEW TABLE), which PostgreSQL does not allow on a partitioned table. Rewrite them as statement triggers (those DO carry a transition table) or drop them, then re-run transmute. pgpm refuses rather than converting and leaving the trigger behind on one child.',
      p_parent, v_bad_trg;
  end if;

  -- 0. incoming FKs (capture before the rename; record after the new parent exists). pgpm never
  -- rewrites the PK, so the referenced unique key (the reused PK) always survives and an incoming FK
  -- can be re-pointed at the new parent verbatim on a later tick -- the 'preserve' lifecycle. It cannot
  -- ride through in place: the rename below makes the ORIGINAL table the monolith child, so a surviving FK
  -- would go on referencing that partition instead of the new parent, silently narrowing to one partition.
  -- We refuse by default (the operator opts into the drop-and-restore dance).
  if exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    if p_incoming_fks = 'error' then
      raise exception
        'pg_partition_magician: % has incoming foreign key(s) (%). Re-run with p_incoming_fks => ''preserve'' to keep them: pgpm drops each for the conversion and re-adds it against the new parent on a later maintenance tick (or call pgpm.restore_incoming_fks to do it now).',
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

  -- ============================ PHASE 1: add the bound (#275) ============================
  --
  -- Certify the monolith's bound BEFORE the rename so the ATTACH below is metadata-only. This is the one
  -- O(rows) read of the conversion, and it gets its own transaction so it is not held under the ACCESS
  -- EXCLUSIVE lock the ADD takes. Measured before the split: the table was fully locked (ACCESS EXCLUSIVE
  -- conflicts with everything, reads included) for 30 ms at 1M rows, 173 ms at 5M, 492 ms at 10M, cached.
  --
  -- A SESSION-level advisory lock is taken first and held across both commits. It is what lets the reaper
  -- below tell "this conversion is still running" from "its session died mid-way", with no heartbeat and no
  -- timeout guess: the lock is released automatically when the session ends, however it ends.
  if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || p_parent::oid::text, 0)) then
    raise exception 'pg_partition_magician: a transmute of % is already in progress in another session', p_parent;
  end if;

  -- Resume: a recorded conversion whose lock we just took means the previous attempt's session is gone.
  -- Reuse its bound rather than recomputing one, because the frontier has moved on since but no row can
  -- have landed outside the recorded range -- the CHECK was rejecting those the whole time.
  select lo, hi into v_lo_prev, v_hi_prev from pgpm.transmute_inflight where parent_table = p_parent;
  if found then
    v_lo_native := v_lo_prev; v_hi_native := v_hi_prev;
    v_monolith  := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native);
    v_resumed := true;
  else
    -- Optional headroom: push hi further out so a fast writer cannot cross it while the scan runs. The
    -- bound rejects writes at or past hi for as long as it is in place, which with the split is the whole
    -- conversion rather than a single locked statement.
    for v_i in 1 .. greatest(coalesce(p_bound_headroom, 0), 0) loop
      v_hi_native := pgpm._grid_next(p_control_kind, p_step, v_hi_native);
    end loop;
    v_monolith := pgpm._part_name(v_rel, p_control_kind, p_step, v_lo_native, v_hi_native);
    insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi)
      values (p_parent, v_nsp, v_rel, p_control_kind, v_lo_native, v_hi_native);
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s add constraint pgpm_monolith_bound check (%I >= %L and %I < %L) not valid',
                   p_parent::text, p_control, pgpm._encode(p_control_kind, v_lo_native),
                   p_control, pgpm._encode(p_control_kind, v_hi_native));
  end if;
  commit;   -- releases the ADD's ACCESS EXCLUSIVE before the scan; the advisory lock survives

  -- ============================ PHASE 2: validate it (#275) ============================
  -- VALIDATE takes only SHARE UPDATE EXCLUSIVE, which blocks nobody. Skipped when a previous attempt
  -- already validated it.
  if not (select convalidated from pg_constraint
           where conrelid = p_parent and conname = 'pgpm_monolith_bound') then
    execute format('alter table %s validate constraint pgpm_monolith_bound', p_parent::text);
  end if;
  commit;

  -- ============================ PHASE 3: the cutover ============================
  -- Metadata only, and atomic: a raise from here rolls the whole cutover back.

  -- 0b. capture what CREATE TABLE ... LIKE will NOT carry (#277): owner, grants, RLS, policies, comments
  -- and triggers. Captured HERE, before the rename, and replayed below in this same transaction. Both
  -- halves have to be inside the cutover: a parent that is briefly reachable with RLS off is the same
  -- security defect as one that never gets its policies, with a shorter fuse.
  --
  -- Trigger definitions get a free ride. pg_get_triggerdef emits "... ON public.<original name>", and
  -- after the rename below that name IS the new parent, so the captured text replays verbatim with no
  -- rewriting. Policies get no such help (there is no pg_get_policydef) and are rebuilt from pg_policy.
  select pg_get_userbyid(relowner), relacl, relrowsecurity, relforcerowsecurity
    into v_owner, v_acl, v_rls, v_rls_force
    from pg_class where oid = p_parent;
  v_comment := obj_description(p_parent, 'pg_class');
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}')
    into v_trgdefs from pg_trigger where tgrelid = p_parent and not tgisinternal;

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

  -- 5. create the partitioned parent under the original name (no PK yet). INCLUDING CONSTRAINTS carries the
  -- user's CHECK constraints onto the parent so every partition (the monolith, the DEFAULT, and future
  -- forward children) enforces them -- without it, only the monolith would. LIKE also copies the transient
  -- pgpm_monolith_bound CHECK (it is on the monolith at this point), which must NOT constrain the parent
  -- (it would reject any row at/after B), so drop it from the parent immediately; the monolith keeps its
  -- own copy for the metadata-only attach below, dropped separately afterward.
  execute format('create table %I.%I (like %s including defaults including generated including storage including constraints) partition by range (%I)',
                 v_nsp, v_rel, v_monreg::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_rel)::regclass;
  execute format('alter table %s drop constraint if exists pgpm_monolith_bound', v_parent::text);

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

  -- 7b. replay everything captured at 0b onto the new parent (#277). Same transaction as the rename and
  -- the attach, so the parent is never reachable without its policies.
  execute format('alter table %s owner to %I', v_parent::text, v_owner);

  -- Grants. aclexplode turns relacl into (grantor, grantee, privilege, grantable) rows; a NULL relacl
  -- means the owner's implicit defaults, which the OWNER TO above already restores. grantee = 0 is
  -- PUBLIC, which has no role name.
  for v_g in
    select a.grantee, a.privilege_type, a.is_grantable
      from pg_class c, aclexplode(c.relacl) a where c.oid = v_monreg and c.relacl is not null
  loop
    execute format('grant %s on %s to %s%s', v_g.privilege_type, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;
  -- COLUMN-level grants, which relacl does not carry at all: they live in pg_attribute.attacl.
  for v_g in
    select att.attname, a.grantee, a.privilege_type, a.is_grantable
      from pg_attribute att, aclexplode(att.attacl) a
     where att.attrelid = v_monreg and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  loop
    execute format('grant %s (%I) on %s to %s%s', v_g.privilege_type, v_g.attname, v_parent::text,
                   case when v_g.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(v_g.grantee)) end,
                   case when v_g.is_grantable then ' with grant option' else '' end);
  end loop;

  -- RLS. FORCE matters as much as ENABLE: without it the table owner bypasses every policy, so an
  -- owner-run query would see all rows and the isolation would be silently absent for exactly the role
  -- most likely to be running reports.
  if v_rls then
    execute format('alter table %s enable row level security', v_parent::text);
  end if;
  if v_rls_force then
    execute format('alter table %s force row level security', v_parent::text);
  end if;
  -- Policies live on the PARENT and only on the parent (measured: a parent policy governs parent-routed
  -- reads into a partition, with no policy on the partition at all). Do not "fix" the apparent gap by
  -- scattering copies onto children; direct partition access needs grants that live on the parent anyway.
  for v_pol in
    select polname, polcmd, polpermissive,
           case when polroles = '{0}'::oid[] then 'public'
                else (select string_agg(quote_ident(rolname), ', ' order by rolname)
                        from pg_roles where oid = any(polroles)) end as roles,
           pg_get_expr(polqual, polrelid)      as qual,
           pg_get_expr(polwithcheck, polrelid) as withcheck
      from pg_policy where polrelid = v_monreg
  loop
    execute format('create policy %I on %s as %s for %s to %s%s%s',
      v_pol.polname, v_parent::text,
      case when v_pol.polpermissive then 'permissive' else 'restrictive' end,
      case v_pol.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update'
                        when 'd' then 'delete' else 'all' end,
      v_pol.roles,
      case when v_pol.qual is not null then ' using (' || v_pol.qual || ')' else '' end,
      case when v_pol.withcheck is not null then ' with check (' || v_pol.withcheck || ')' else '' end);
  end loop;

  if v_comment is not null then
    execute format('comment on table %s is %L', v_parent::text, v_comment);
  end if;
  for v_colcom in
    select a.attname, col_description(v_monreg, a.attnum) as c
      from pg_attribute a
     where a.attrelid = v_monreg and a.attnum > 0 and not a.attisdropped
       and col_description(v_monreg, a.attnum) is not null
  loop
    execute format('comment on column %s.%I is %L', v_parent::text, v_colcom.attname, v_colcom.c);
  end loop;

  -- Triggers LAST, and the monolith's own originals are dropped FIRST. Creating on the parent clones the
  -- trigger onto every partition including the monolith, so leaving the original in place would give the
  -- monolith two and fire it twice for every row routed there. Order is the whole correctness argument.
  if array_length(v_trgdefs, 1) > 0 then
    for v_trg in select tgname from pg_trigger where tgrelid = v_monreg and not tgisinternal loop
      execute format('drop trigger %I on %s', v_trg.tgname, v_monreg::text);
    end loop;
    foreach v_grant in array v_trgdefs loop
      execute v_grant;   -- names the ORIGINAL table, which is now the parent: replays verbatim
    end loop;
  end if;

  -- 8. parent key -- adopts the monolith's kept constraint index (metadata-only, no rebuild): a PRIMARY
  -- KEY when the reused key was the PK, a UNIQUE constraint when it was a unique constraint.
  if v_add_pk then
    execute format('alter table %s add primary key (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  elsif v_add_uniq then
    execute format('alter table %s add unique (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  end if;

  -- 8b. advance each identity sequence to the greater of max(id)+1 (no collision with existing rows) and the
  -- original sequence's own next value (no re-issue of ids it already handed out past max). Both captured up
  -- front; the max is an index lookup.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_parent::text, v_idcols[v_i], greatest(v_idmax[v_i] + 1, coalesce(v_idnext[v_i], 0)));
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

  -- 9c. NO default partition (#288). It used to sit here as the leading-edge safety net, and the drain
  -- existed to evacuate it. Instead the forward grid is built below, after registration, so a write past
  -- the monolith lands in a real bounded partition. A write past the GRID now fails outright, which is
  -- the accepted cost: obtain x partition_step is both the slack and a hard write-ahead ceiling.

  -- 10. register
  insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                           obtain, retain, regrain_batch, paused)
  values (v_parent, p_control, p_control_kind, p_step, p_anchor, p_obtain, p_retain,
          p_regrain_batch, p_paused)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, control_kind = excluded.control_kind,
    partition_step = excluded.partition_step, partition_anchor = excluded.partition_anchor,
    obtain = excluded.obtain, retain = excluded.retain,
    regrain_batch = excluded.regrain_batch, paused = excluded.paused;

  insert into pgpm.log (parent_table, action) values (v_parent, 'transmute');
  -- keyed on v_parent, not p_parent: after the rename p_parent's oid is the monolith's, so an operator
  -- looking the table up by name would never see it (#275).
  if v_resumed then
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (v_parent, 'transmute_resume', v_lo_native, v_hi_native, 'reused the recorded bound');
  end if;

  -- record the original table, now the bounded MONOLITH coarse child, as an attached partition
  -- (REDESIGN.md section 7) so obtain's overlap check and status() see it.
  insert into pgpm.part (parent_table, child_name, lo, hi, attached)
    values (v_parent, v_monolith, v_lo_native, v_hi_native, true);

  -- record any dropped incoming FKs (the recorded definition already names the new parent); these are
  -- always preserve-managed now, re-added against the new parent by restore_incoming_fks on a later tick.
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

  -- Build the forward grid (#288). With no DEFAULT, a write past the monolith has nowhere to go until
  -- these exist, so they are created here rather than waiting for the first maintenance tick. obtain needs
  -- no special casing: the frontier sits inside the monolith, so its k=0 candidate overlaps and is skipped,
  -- and k=1 onward lays down [B, B + obtain x step) flush against the monolith's upper bound.
  perform pgpm.obtain(v_parent);

  -- the conversion is complete: nothing is left for the reaper to undo, and the advisory lock can go.
  delete from pgpm.transmute_inflight where parent_table = p_parent;
  perform pg_advisory_unlock(hashtextextended('pgpm_transmute:' || p_parent::oid::text, 0));
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
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false,
  p_bound_headroom int default 0
) language plpgsql as $$
declare v_kind text;
begin
  -- resolved into a variable first: a CALL argument may not contain a subquery
  select case when t.typname = 'uuid' then 'uuidv7' else 'time' end into v_kind
    from pg_attribute a join pg_type t on t.oid = a.atttypid
   where a.attrelid = p_parent and a.attname = p_control and not a.attisdropped;
  call pgpm._transmute(p_parent, p_control, coalesce(v_kind, 'time'),
    p_interval::text, p_anchor::text, p_obtain,
    p_retain::text, p_regrain_batch, p_paused, p_incoming_fks, p_force_uuidv7,
    p_bound_headroom);
end;
$$;

-- Integer grid: bigint width. Covers int/bigint/numeric keys, including Snowflake-style ids.
create or replace procedure pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 30, p_retain bigint default null,
  p_regrain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_bound_headroom int default 0
) language plpgsql as $$
begin
  -- plpgsql, not sql: a SQL-bodied routine cannot host a callee's transaction control
  call pgpm._transmute(p_parent, p_control, 'id', p_step::text, p_anchor::text, p_obtain,
                     p_retain::text, p_regrain_batch, p_paused, p_incoming_fks,
                     false, p_bound_headroom);
end;
$$;

-- Abandon a half-finished conversion (issue #275). transmute runs in three transactions, so a failure
-- between them leaves a validated-or-not `pgpm_monolith_bound` CHECK on the operator's table, and that
-- CHECK REJECTS every write outside [lo, hi) for as long as it is there. This puts the table back exactly
-- as it was.
--
-- It ABANDONS, it does not resume: finishing someone's half-done conversion of a production table
-- unattended is too large an action to take on their behalf. Re-run transmute to try again; it will resume
-- from the recorded bound.
create or replace function pgpm.transmute_abort(p_parent regclass)
returns boolean language plpgsql as $$
declare r pgpm.transmute_inflight%rowtype;
begin
  select * into r from pgpm.transmute_inflight where parent_table = p_parent;
  if not found then return false; end if;
  if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || p_parent::oid::text, 0)) then
    raise exception 'pg_partition_magician: cannot abort the transmute of % -- it is still running in another session', p_parent;
  end if;
  execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);
  delete from pgpm.transmute_inflight where parent_table = p_parent;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (p_parent, 'transmute_abort', r.lo, r.hi, 'bound dropped, table restored');
  perform pg_advisory_unlock(hashtextextended('pgpm_transmute:' || p_parent::oid::text, 0));
  return true;
end;
$$;

-- The reaper (issue #275). A conversion whose session died leaves the bound behind, and the table goes on
-- rejecting out-of-range writes until someone notices. Rather than leave that to the operator, every
-- maintain_all tick sweeps for abandoned conversions and undoes them.
--
-- "Abandoned" is decided by the session advisory lock transmute holds for its whole run, not by a timeout:
-- if the lock can be taken, the owning session is gone, whatever the reason. A long validation scan is
-- therefore never mistaken for a dead one, and an operator whose session is still open keeps the right to
-- retry -- the sweep waits until they disconnect.
--
-- Deliberately independent of pgpm.config: a half-converted table is not registered yet, because
-- registration happens in the cutover. That is exactly why this lives in maintain_all rather than maintain.
create or replace function pgpm._transmute_reap()
returns int language plpgsql as $$
declare r pgpm.transmute_inflight%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.transmute_inflight loop
    -- the relation itself is gone: nothing to undo, just forget it
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = r.nsp and c.relname = r.rel) then
      delete from pgpm.transmute_inflight where parent_table = r.parent_table;
      v_n := v_n + 1;
      continue;
    end if;
    if not pg_try_advisory_lock(hashtextextended('pgpm_transmute:' || r.parent_table::oid::text, 0)) then
      continue;   -- still running; leave it alone
    end if;
    execute format('alter table %I.%I drop constraint if exists pgpm_monolith_bound', r.nsp, r.rel);
    delete from pgpm.transmute_inflight where parent_table = r.parent_table;
    insert into pgpm.log (parent_table, action, lo, hi, method)
      values (r.parent_table, 'transmute_reap', r.lo, r.hi,
              'abandoned conversion undone: the bound was rejecting out-of-range writes');
    perform pg_advisory_unlock(hashtextextended('pgpm_transmute:' || r.parent_table::oid::text, 0));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- _detach_reap(): finish any concurrent detach whose session died part-way (issue #268).
--
-- Retiring a referenced partition dispatches `DETACH PARTITION ... CONCURRENTLY` to pg_cron, so the
-- detach genuinely runs in another session, and that session can die. Measured: a backend killed
-- during the detach's SCAN phase rolls back cleanly and leaves nothing behind, but one killed during
-- its WAIT phase -- reachable whenever any concurrent transaction still holds a snapshot on the parent
-- -- leaves the partition flagged `pg_inherits.inhdetachpending` AND its rows already invisible
-- through the parent (a 2,000,000-row parent read 1,000,000). The partition is then neither detached
-- nor dropped, and rows have silently vanished from the user's table: strictly worse than the wedge
-- this all exists to fix. `DETACH ... FINALIZE` completes it and clears the flag.
--
-- So this runs BEFORE the per-parent loop in maintain_all, like _transmute_reap: it is the most urgent
-- thing in a tick. It FINALIZES unconditionally, because a pending detach is never a state to leave
-- sitting, but it DROPS nothing -- retire() completes its own retirements on the normal path (it can
-- tell, from pgpm.part.retiring_at, which detach was its own), and an operator's hand-run detach that
-- was interrupted is finished and then left alone.
create or replace function pgpm._detach_reap()
returns int language plpgsql as $$
declare r record; v_n int := 0;
begin
  for r in
    select pn.nspname as pnsp, pc.relname as prel,
           cn.nspname as cnsp, cc.relname as crel,
           i.inhparent::regclass as parent
      from pg_inherits i
      join pg_class cc on cc.oid = i.inhrelid
      join pg_namespace cn on cn.oid = cc.relnamespace
      join pg_class pc on pc.oid = i.inhparent
      join pg_namespace pn on pn.oid = pc.relnamespace
     where i.inhdetachpending
       and i.inhparent in (select parent_table from pgpm.config)
  loop
    begin
      execute format('alter table %I.%I detach partition %I.%I finalize',
                     r.pnsp, r.prel, r.cnsp, r.crel);
      insert into pgpm.log (parent_table, action, lo, hi, method)
        select r.parent, 'detach_reap', p.lo, p.hi,
               'an abandoned concurrent detach was finalized; its rows were already invisible through the parent'
          from pgpm.part p
         where p.parent_table = r.parent and p.child_name = r.crel;
      v_n := v_n + 1;
    exception when others then
      insert into pgpm.log (parent_table, action, method)
        values (r.parent, 'fail_detach_reap', left(sqlerrm, 200));
    end;
  end loop;
  return v_n;
end;
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
  v_idcols name[]; v_idmax bigint[]; v_col name; v_m bigint; v_i int; v_idnext bigint[]; v_seq text; v_n bigint;
  r pgpm.dropped_fk%rowtype; v_cdelta name; v_cfn name;
  v_trgdefs text[] := '{}'; v_tdef text;   -- #277
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then
    raise exception 'pg_partition_magician: % is not managed by pgpm (nothing to untransmute)', p_parent;
  end if;

  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_ncast := pgpm._native_type(cfg.control_kind);
  -- resolve the regrain change-capture names (#267) NOW, while the parent still exists: they are derived
  -- from it, and the drop below would leave the lookup with nothing to read.
  select delta, fn into v_cdelta, v_cfn from pgpm._regrain_capture_names(p_parent);

  -- THE GATE (REDESIGN.md section 13): a clean (metadata-only) reverse needs the original table still
  -- intact as the MONOLITH, holding the whole table, with nothing landed outside it. The monolith is the
  -- attached partition with the smallest lo (it starts at grid_floor(min(control)), strictly below B,
  -- while every forward partition starts at B or higher). The reverse is a one-way door once any row
  -- lives outside the monolith's [lo, hi): a forward partition after the frontier crosses B, a backdated
  -- stray in the DEFAULT, or finer children from a regraining (Tier 2 foldback / Tier 3 merge not built).
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
    raise exception 'pg_partition_magician: cannot untransmute % -- rows now live outside the original monolith (a forward partition past B, a backdated stray, or a regraining has split it), so a metadata-only reverse would lose data. This is a one-way door once the frontier crosses B or regraining begins.',
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
      -- capture the parent sequence's position too (it holds whatever transmute preserved), so the reversal
      -- does not reopen a gap above max that transmute had carried forward.
      v_seq := pg_get_serial_sequence(p_parent::text, v_col);
      v_n := null;
      if v_seq is not null then
        execute format('select case when is_called then last_value + 1 else last_value end from %s', v_seq) into v_n;
      end if;
      v_idnext := array_append(v_idnext, v_n);
    end loop;
  end if;

  -- preserved incoming FKs: drop any currently LIVE on the parent so the parent can be dropped (an
  -- incoming FK is a constraint on the referencing table pointing AT the parent). All recorded FKs are
  -- re-added against the restored table at the end.
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null order by id loop
    execute format('alter table %s drop constraint %I', r.referencing_table::text, r.constraint_name);
  end loop;

  -- Capture the parent's triggers before it is dropped (#277). transmute dropped the monolith's own
  -- originals in favour of the parent's, which clone down to every partition, and DETACH strips those
  -- clones -- so without this the reversal silently returns a table with no triggers at all. As in
  -- transmute, pg_get_triggerdef names the PARENT, and the restored table takes that name back below, so
  -- the definitions replay verbatim.
  select coalesce(array_agg(pg_get_triggerdef(oid) order by tgname), '{}')
    into v_trgdefs from pg_trigger where tgrelid = p_parent and not tgisinternal;

  -- detach the MONOLITH (the original table, holding everything; PK + secondary indexes intact), then
  -- drop the childless parent -- which cascades the empty DEFAULT and any empty forward partitions, and
  -- takes the parent PK, the partitioned _pgpm indexes, and the parent's identity sequence with it.
  -- DETACH FIRST: dropping a partitioned parent cascades to its partitions, which would destroy the data.
  execute format('alter table %s detach partition %s', p_parent::text, v_monreg::text);
  execute format('drop table %s', p_parent::text);

  -- re-establish identity on the restored monolith and reseed to the greater of max+1 and the parent
  -- sequence's preserved position (mirrors transmute's step 6/8b, applied back to the table); without the
  -- reseed the next insert would collide at 1.
  if v_idcols is not null then
    for v_i in 1 .. array_length(v_idcols, 1) loop
      execute format('alter table %s alter column %I add generated by default as identity',
                     v_monreg::text, v_idcols[v_i]);
      execute format('select setval(pg_get_serial_sequence(%L, %L), %s, false)',
                     v_monreg::text, v_idcols[v_i], greatest(v_idmax[v_i] + 1, coalesce(v_idnext[v_i], 0)));
    end loop;
  end if;

  -- rename the monolith back to the original table name. (transmute never renamed the kept PK or
  -- secondary indexes, so those names are already the originals.)
  execute format('alter table %s rename to %I', v_monreg::text, v_rel);
  v_restored := format('%I.%I', v_nsp, v_rel)::regclass;

  -- Replay the captured triggers onto the restored table, now that it carries the original name again.
  foreach v_tdef in array v_trgdefs loop
    execute v_tdef;
  end loop;

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

  -- the per-parent regrain change-capture apparatus (#267) is a side relation, not a partition, so the
  -- parent's DROP above does not take it. Drop it here or untransmute leaves it orphaned. Names were
  -- resolved up front, before the parent went away.
  execute format('drop table if exists %I.%I', v_nsp, v_cdelta);
  execute format('drop function if exists %I.%I()', v_nsp, v_cfn);

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

-- Adaptive feathering removed with the drain (#288): it existed to pace the drain's microbatches
-- against WAL supply and ambient I/O. Nothing else in pgpm is paced by row volume.

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
-- set_drain_adaptive / set_drain_ambient removed with adaptive feathering (#288). They tuned the closed
-- loop that paced the drain's microbatches against WAL supply and ambient I/O. Nothing left in pgpm is
-- paced by row volume: regrain has its own fixed batch, and obtain is pure metadata.


-- Operator switch for auto-regrain (REDESIGN.md sec 12). p_target_step (an interval for time/uuidv7, a
-- bigint step as text for id) turns it on: each maintenance tick feathers the oldest frozen coarse child
-- one budget-sized microbatch toward that granularity. null turns it off (regrain stays operator-driven via
-- regrain()/regrain_history()). This only PACES regraining across ticks; regrain_step enforces its own
-- preconditions (frozen, default-clear), so enabling it is always safe.
create or replace function pgpm.set_regrain(p_parent regclass, p_target_step text default null)
returns void language plpgsql as $$
begin
  update pgpm.config set regrain_to = p_target_step where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
end;
$$;

-- Operator switch for the archive-before-drop strategy (issue #236's config.archive_fn contract).
-- p_archive_fn names any (p_parent regclass, p_child name, p_lo text, p_hi text) returns
-- pgpm.archive_result function -- pgpm_archive ships two (pgpm.archive_to_s3_ndjson/
-- archive_to_s3_parquet), or bring your own. Casting the argument to regprocedure validates that
-- the function exists with exactly this signature right away, not later when a maintenance tick
-- tries to call it. null (the default) turns archiving off: retire()'s drop precondition then only
-- waits on the write-block, never on coverage.
create or replace function pgpm.set_archive_fn(p_parent regclass, p_archive_fn regprocedure default null)
returns void language plpgsql as $$
begin
  update pgpm.config set archive_fn = p_archive_fn where parent_table = p_parent;
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

-- #279: maintain became a PROCEDURE. CREATE OR REPLACE cannot turn a function into a procedure, so the
-- old function has to go first or the installer fails on an upgrade with "cannot change routine kind".
drop function if exists pgpm.maintain(regclass);

-- maintain(): one tick of the lifecycle for one table.
--
-- A PROCEDURE, not a function, because a tick MUST NOT be one transaction (issue #279). obtain takes
-- ACCESS EXCLUSIVE on the parent (CREATE TABLE ... PARTITION OF) and on the DEFAULT. Locks release only
-- at transaction end, so in a single-transaction tick those were held across everything that followed,
-- including the drain -- whose duration is proportional to drain_batch. On the PARENT that blocks readers
-- too, so the whole table stalled for the length of a drain batch on every tick where obtain happened to
-- create a partition. Measured at 926 ms for a 400k batch against 96 ms for a 5k one: 10x the batch, 10x
-- the stall. That is the shape issue #263's acceptance rule exists to forbid.
--
-- So each step commits before the next begins, and no step's locks outlive it. The COMMITs sit at the top
-- level between the steps, never inside one: transaction control is illegal inside a block with an
-- EXCEPTION handler, and each step keeps its handler so a lock race still DEFERS that step alone rather
-- than aborting the tick.
--
-- The status is reported through an INOUT parameter, which is how a procedure returns anything. Callers
-- that do not care can `call pgpm.maintain(t)` and ignore it.
--
-- CAUTION for anyone adding a step: `set local` dies at COMMIT. lock_timeout is therefore re-applied
-- after every boundary below, and a new step placed after a COMMIT without re-applying it silently runs
-- with the session default -- which for obtain means waiting indefinitely for a lock it is designed to
-- fail fast on.
create or replace procedure pgpm.maintain(p_parent regclass, inout p_status text default null)
language plpgsql as $$
declare
  cfg pgpm.config;
  v_made int := 0; v_archived int := 0; v_dropped int := 0; v_restored int := 0;
  v_regrain text := 'skipped'; v_regrain_child name; v_validated int := 0;
  v_note text := '';
  v_batch int := null; v_ckpt bigint; v_congested boolean; v_budget int; v_deferred boolean;
  v_now_lsn pg_lsn; v_now_ts timestamptz; v_secs numeric; v_obs_bps numeric;
  v_waiters int; v_wal_cong boolean; v_amb_cong boolean; v_reason text;
  v_lock_surge boolean; v_lock_abs boolean; v_amb_baseline numeric;
  v_io_time numeric; v_io_blks bigint; v_io_lat numeric; v_io_surge boolean; v_io_baseline numeric;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then p_status := 'paused'; return; end if;

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
    -- Back inside a handler (#288). obtain no longer commits -- with no DEFAULT there is no
    -- exclusion-constraint dance and no phases -- so the wrapper is legal again, and a lock race here is
    -- deferred like any other step. This is now the ONLY thing standing between the workload and a write
    -- with nowhere to go, so a deferral also starts the back-off rather than retrying every tick.
    begin
      v_made := pgpm.obtain(p_parent);
      if cfg.obtain_retry_after is not null then
        update pgpm.config set obtain_retry_after = null where parent_table = p_parent;
      end if;
    exception when others then
      v_note := v_note || ' obtain_deferred';
      update pgpm.config set obtain_retry_after = clock_timestamp() + interval '30 seconds'
        where parent_table = p_parent;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_obtain', left(sqlerrm, 200));
    end;
  else
    v_note := v_note || ' obtain_backoff';
  end if;

  -- BOUNDARY (#279). This is the one that matters: it drops obtain's ACCESS EXCLUSIVE on the parent and
  -- the DEFAULT before the drain, so the stall lasts obtain's own duration instead of the whole tick.
  commit;
  perform set_config('lock_timeout', '200ms', true);   -- `set local` did not survive the COMMIT

  -- Write-block on retain-eligibility (issue #235), ahead of retain()'s own drop logic: a partition
  -- is blocked from writes the instant it crosses the boundary, whether or not (or how far along)
  -- it is being archived. One of retire()'s two drop preconditions (#238; the other is archive
  -- coverage, below).
  begin
    perform pgpm._enforce_write_blocks(p_parent);
    perform pgpm._enforce_regrain_capture(p_parent);   -- #267: reap capture left by an abandoned regrain
  exception when others then
    v_note := v_note || ' write_block_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_write_block', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). Installing a write-block trigger takes ACCESS EXCLUSIVE on the child. The archive
  -- step below then reads that same child for a whole byte budget, which is O(bytes), so without this
  -- the trigger's lock would cover the read.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  -- Byte-budget chunked archiving (issue #237), one tick's worth per write-blocked, not-yet-covered
  -- child: only ever runs after the write-block step above, on children that step has already
  -- protected. retire()'s other drop precondition (#238) -- a child only drops once this has fully
  -- covered it.
  begin
    v_archived := pgpm._archive_step(p_parent);
  exception when others then
    v_note := v_note || ' archive_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_archive', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279): make a whole tick's archived bytes durable before anything else runs. Chunked
  -- archiving exists so a large child is covered over many ticks; folding a tick's chunk into the same
  -- transaction as the drain would mean a drain failure discards archive progress that was already paid for.
  commit;
  perform set_config('lock_timeout', '200ms', true);

  begin
    v_dropped := pgpm.retain(p_parent);
  exception when others then
    v_note := v_note || ' retain_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_retain', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#279). retain DROPs partitions, which takes ACCESS EXCLUSIVE on the parent. Also releases
  -- the FOR UPDATE SKIP LOCKED claim retain holds on each pgpm.part row it worked, which would otherwise
  -- be held against other retirement actors for the rest of the tick.
  commit;

  -- Adaptive feathering, the drain step, and the FK suspension that guarded it are all gone (#288).
  -- They existed to pace and protect the evacuation of the DEFAULT partition; with a complete forward
  -- grid there is nothing to evacuate. What remains of a tick is obtain, archive, retain, regrain and the
  -- FK restore -- none of which is paced by row volume.

  -- Auto-regrain target: the oldest FROZEN coarse child (if auto-regrain is on). A coarse child (hi > one
  -- step past lo) is frozen once its whole range is at/below the current grid floor (no live write still
  -- lands in it). Found here so the auto-regrain block below can use it.
  if cfg.regrain_to is not null then
    execute format(
      'select child_name from pgpm.part p where p.parent_table = %L::regclass and p.attached'
      || ' and pgpm._native_gt(%L, p.hi, pgpm._grid_next(%L, %L, p.lo))'
      || ' and not pgpm._native_gt(%L, p.hi, %L) order by p.lo::%s asc limit 1',
      p_parent::text, cfg.control_kind, cfg.control_kind, cfg.partition_step,
      cfg.control_kind,
      pgpm._grid_floor(cfg.control_kind, cfg.partition_step, cfg.partition_anchor, pgpm._frontier_native(p_parent)),
      pgpm._native_type(cfg.control_kind))
      into v_regrain_child;
    v_batch := cfg.regrain_batch;   -- regrain's own microbatch size
  end if;

  -- Auto-regrain (REDESIGN.md sec 12): feather the oldest frozen coarse child (found up front as
  -- v_regrain_child) one budget-sized COPY microbatch toward regrain_to per tick, under the same adaptive
  -- budget as the drain. Isolated in its own subtransaction; a lock race or a soft status just retries next
  -- tick. Unlike the drain, regrain COPIES and never deletes: the source stays whole and attached until the
  -- atomic swap, so it never moves a referenced row out of the parent, never opens the snapshot() gap, and
  -- needs NO FK leash -- it is NOT gated on a live preserve FK and runs whether or not one is suspended.
  if v_regrain_child is not null then
    begin
      v_regrain := pgpm.regrain_step(p_parent, v_regrain_child, cfg.regrain_to, v_batch);
    exception when others then
      v_regrain := 'deferred';
      v_note := v_note || ' regrain_deferred';
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_regrain', left(sqlerrm, 200));
    end;
  elsif cfg.regrain_to is not null then
    v_regrain := 'none';   -- auto-regrain on, but no frozen coarse child to work
  end if;

  -- BOUNDARY (#279). regrain_step's swap is atomic within itself; this only stops its locks reaching
  -- the FK restore below, which re-adds a foreign key and so takes locks of its own on both sides.
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Re-add any incoming FKs that transmute(..., 'preserve') dropped, now against the new parent, AFTER
  -- the regrain has moved this tick. restore_incoming_fks self-gates on quiescence (no in-flight,
  -- not-yet-attached child), so while a multi-tick regrain is mid-flight it stays a no-op and
  -- the FK remains suspended (RI off, surfaced by status().fks_suspended), re-adding only once the regrain
  -- has swapped in its fine children. Isolated: a hiccup here never aborts progress.
  begin
    v_restored := pgpm.restore_incoming_fks(p_parent);
  exception when others then
    v_note := v_note || ' restore_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_restore_fk', left(sqlerrm, 200));
  end;

  -- BOUNDARY (#265). The restore above re-adds the FK NOT VALID and stops, which takes SHARE ROW
  -- EXCLUSIVE on the managed parent -- briefly, since NOT VALID scans nothing. This drops that lock
  -- BEFORE the validation scan below, which is the entire point: the two used to share a transaction and
  -- the scan ran under the ADD's lock, blocking writes on the parent for O(referencing table).
  commit;
  perform set_config('lock_timeout', '3s', true);

  -- Finish the validation, in its own transaction, where the VALIDATE holds only SHARE UPDATE EXCLUSIVE
  -- on the referencing table and ROW SHARE on the parent -- neither of which blocks writes. Usually the
  -- tick after the restore. p_respect_backoff so an FK blocked by a pre-existing orphan parks for five
  -- minutes rather than re-scanning the referencing table every tick to learn the same thing.
  begin
    v_validated := pgpm.validate_incoming_fks(p_parent, p_respect_backoff => true);
    if v_validated > 0 then v_note := v_note || format(' validated_fk[%s]', v_validated); end if;
  exception when others then
    v_note := v_note || ' validate_fk_deferred';
    insert into pgpm.log (parent_table, action, method) values (p_parent, 'skip_validate_fk', left(sqlerrm, 200));
  end;

  p_status := format('obtained=%s archived=%s dropped=%s restored_fk=%s regrain=%s%s',
                     v_made, v_archived, v_dropped, v_restored, v_regrain, v_note);
end;
$$;

create or replace procedure pgpm.maintain_all()
language plpgsql as $$
-- v_status exists only to receive maintain()'s INOUT: PL/pgSQL requires a writable argument for an
-- output parameter, so the parameter's default cannot be relied on here. The sweep discards it; the
-- per-parent detail is already in pgpm.log.
declare r record; v_status text;
begin
  -- #275: undo any conversion whose session died mid-way, before anything else. Independent of
  -- pgpm.config on purpose: a half-converted table is not registered yet.
  perform pgpm._transmute_reap();
  -- #268: and any concurrent detach whose session died mid-way, for the same reason and with more
  -- urgency -- a partition left pending has its rows already invisible through the parent.
  perform pgpm._detach_reap();
  commit;

  -- One transaction per parent, not one for the whole sweep (#279). Two reasons. Locks: without it,
  -- every parent's locks accumulate until the last one is done, so a ten-table sweep ends holding ten
  -- tables' worth. Progress: a parent that raises no longer costs the parents before it their work.
  --
  -- Ordered so a sweep is reproducible: same tables, same order, every tick, which makes pgpm.log
  -- readable and a partial sweep's stopping point meaningful.
  --
  -- Deliberately NO exception handler around the call. One would abort the whole sweep on the first
  -- failing parent -- and worse, transaction control is illegal anywhere below an EXCEPTION handler, so
  -- wrapping this would silently disable every COMMIT inside maintain() and put the locks straight back.
  -- maintain() already isolates each of its own steps, so the raises that reach here are the ones that
  -- should stop a sweep: a table that is not managed, or a config row pointing at something gone.
  for r in select parent_table from pgpm.config order by parent_table loop
    call pgpm.maintain(r.parent_table, v_status);
    commit;
  end loop;
end;
$$;

-- schedule()/unschedule(): a thin convenience wrapper around pg_cron for the two jobs pgpm needs, so the
-- operator does not hand-write the cron incantation. pgpm never schedules on its own (transmute stays
-- pg_cron-free, and a tick can be driven by hand with maintain/maintain_all); this is the deliberate,
-- discoverable way to turn the scheduled lifecycle on. One canonical job named 'pgpm' calls
-- maintain_all() for ALL managed tables, so it is scheduled once, not per table, and re-scheduling
-- updates the interval rather than duplicating. The second, 'pgpm_detach', is idle machinery for
-- issue #268 and is described at its creation below; it is required only for retiring a partition
-- that an incoming foreign key references. It targets current_database() via schedule_in_database,
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
  -- The second job exists solely as a place for retire() to put a `DETACH PARTITION ... CONCURRENTLY`
  -- (issue #268), which PostgreSQL refuses to execute from a function but a cron job runs as a
  -- top-level statement. It is created IDLE and stays idle until a REFERENCED partition needs
  -- retiring, at which point retire() rewrites its command in place and returns it to `select 1` once
  -- the drop lands. One standing job, rewritten, rather than one per retirement: pg_cron has no
  -- one-shot schedule, so a per-retirement job would keep firing after it succeeded.
  execute format('select cron.schedule_in_database(%L, %L, %L, %L)',
                 'pgpm_detach', p_every, 'select 1', current_database());
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
       || 'where jobname in (''pgpm'', ''pgpm_detach'') and database = current_database()) s' into v_n;
  return v_n;
end;
$$;

-- forget_missing(): clear pgpm's state for managed tables whose relation no longer exists (issue #296).
--
-- `pgpm.untransmute` is the sanctioned way to stop managing a table, and it deletes the pgpm rows. A plain
-- `DROP TABLE` does not: pgpm.config.parent_table is a regclass, which carries no dependency, so the row
-- survives pointing at a dead oid. Nothing then cleans it up, ever, and the consequences are permanent --
-- every maintenance tick logs skip_obtain / skip_write_block / skip_retain for it, and (before #296)
-- status() raised rather than reporting anything at all. There is a second, quieter reason not to leave it
-- sitting: pg_class oids are recycled, so a stale row is a standing chance of pgpm one day believing it
-- manages an unrelated table that happens to land on that oid.
--
-- Takes NO ARGUMENT deliberately. The relation is gone, so there is no name to pass, and an oid parameter
-- would be a foot-gun; with no argument the function can only ever match rows whose relation is ALREADY
-- absent, so by construction it cannot touch a live managed table. That is why this is safe to expose and
-- safe to re-run.
--
-- It DELETES pgpm's own bookkeeping and DROPS NOTHING. A detached partition survives its parent's DROP
-- still holding its rows (measured on PG 17.10) -- and "detached, not yet dropped" is exactly the state a
-- referenced partition's retirement sits in between the cron detach and the completing drop (#268). Those
-- tables are REPORTED in orphan_tables, by name, and left alone: destroying data as a side effect of a
-- cleanup command would be the worst possible reading of "forget". pgpm.log is left intact too -- it is an
-- append-only audit trail, and the history of a table that once existed is still history.
create or replace function pgpm.forget_missing()
returns table (parent_oid oid, partitions_forgotten int, orphan_tables text[])
language plpgsql as $$
declare r record; v_orphans text[]; v_parts int;
begin
  for r in
    select c.parent_table, c.parent_table::oid as oid
      from pgpm.config c
     where not exists (select 1 from pg_class k where k.oid = c.parent_table)
     order by c.parent_table::oid
  loop
    -- Children pgpm still has a row for that are STILL PRESENT on disk: everything attached went with the
    -- parent's DROP, so anything left here was detached first and is holding data nobody agreed to lose.
    --
    -- Matched on the child NAME alone, because pgpm.part records no namespace and the dropped parent's oid
    -- can no longer supply one. So this can in principle name a same-named table in an unrelated schema.
    -- Reported SCHEMA-QUALIFIED for exactly that reason: an operator acting on this list has to be able to
    -- see which table is meant, and if two schemas collide both are listed rather than one being guessed
    -- at. relkind filtered to tables/partitioned tables so an index or sequence sharing the name cannot
    -- appear as data at risk.
    select coalesce(array_agg(format('%I.%I', n.nspname, k.relname) order by n.nspname, k.relname),
                    '{}'::text[])
      into v_orphans
      from pgpm.part p
      join pg_class k on k.relname = p.child_name and k.relkind in ('r', 'p')
      join pg_namespace n on n.oid = k.relnamespace
     where p.parent_table = r.parent_table;

    select count(*)::int into v_parts from pgpm.part where parent_table = r.parent_table;

    delete from pgpm.transmute_inflight where parent_table = r.parent_table;
    delete from pgpm.archive_ledger     where parent_table = r.parent_table;
    delete from pgpm.dropped_fk         where parent_table = r.parent_table;
    delete from pgpm.part               where parent_table = r.parent_table;
    delete from pgpm.config             where parent_table = r.parent_table;

    insert into pgpm.log (parent_table, action, rows, method)
      values (r.parent_table, 'forget_missing', v_parts,
              case when coalesce(array_length(v_orphans, 1), 0) = 0
                   then 'relation was gone; pgpm state cleared'
                   else format('relation was gone; pgpm state cleared. LEFT IN PLACE (still hold data): %s',
                               array_to_string(v_orphans, ', ')) end);

    parent_oid := r.oid; partitions_forgotten := v_parts; orphan_tables := v_orphans;
    return next;
  end loop;
end;
$$;

-- check_default removed with the DEFAULT partition (#288).

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

-- status(): the operator's at-a-glance view.
--
-- The drain-wedge columns are gone with the drain (#288): default_rows, closed_rows, default_oldest,
-- last_drained and drain_skips all described a backlog in a DEFAULT partition that no longer exists.
-- inflight_partitions stays, but now counts only REGRAIN copy-children not yet attached.
--
-- fks_suspended / fks_unvalidated surface preserve-managed incoming FK state (issue #95):
-- fks_suspended = incoming FKs currently DROPPED (RI off on the referencing table). That is now a
-- transient, sub-transaction state inside regrain's swap rather than something spanning a drain
-- campaign, so a standing non-zero value means a swap died mid-flight. fks_unvalidated = FKs re-added
-- NOT VALID (enforcing new writes) but blocked from full validation by pre-existing orphans (see
-- incoming_fk_orphans() / validate_incoming_fks()).
-- parent_missing (#296) says the managed relation itself is gone -- dropped without untransmute, so the
-- config row is pointing at an oid with no pg_class entry. status() used to RAISE on such a row and
-- therefore return nothing for any table; now it reports it, since naming the dead table is the most
-- useful thing it can do. pgpm.forget_missing() clears the state.
--
-- dropped/recreated (not CREATE OR REPLACE) because the redesign widens the return shape with
-- coarse_partitions + history_unregrained (REDESIGN.md section 14), and again for parent_missing (#296).
drop function if exists pgpm.status();
create or replace function pgpm.status()
returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text,
  fks_suspended bigint, fks_unvalidated bigint, history_unregrained boolean, retain_drop_failures bigint,
  retain_backlog bigint, retain_detaching bigint, parent_missing boolean
)
language plpgsql as $$
declare
  r pgpm.config; v_nsp name; v_np bigint; v_coarse bigint; v_inflight bigint; v_new text;
  v_missing boolean;

  v_fks_susp bigint; v_fks_unval bigint;
  v_last_retain_id bigint; v_drop_fails bigint; v_detaching bigint;
  v_retain_boundary text; v_retain_backlog bigint;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;

    -- Has the managed relation been dropped out from under us (#296)? status() is the DIAGNOSTIC, so it
    -- must never be the thing that dies: one config row pointing at a vanished oid used to raise out of
    -- this whole set-returning function, so a single dropped table returned NOTHING for every managed
    -- table, healthy ones included. Everything below except retain_backlog comes from pgpm.part /
    -- pgpm.config / pgpm.log, so a dead parent still gets a full, useful row -- and the flag says which
    -- one it is, which is the single most actionable thing to report here.
    v_missing := not exists (select 1 from pg_class c where c.oid = r.parent_table);

    -- n_partitions = attached (real) partitions; coarse_partitions = the un-regrained coarse children (a
    -- wider-than-one-step range, REDESIGN.md section 14) -- the regraining backlog; inflight = the
    -- not-yet-attached drain/regrain children.
    select count(*) filter (where attached),
           count(*) filter (where attached
                            and pgpm._native_gt(r.control_kind, hi, pgpm._grid_next(r.control_kind, r.partition_step, lo))),
           count(*) filter (where not attached)
      into v_np, v_coarse, v_inflight from pgpm.part where parent_table = r.parent_table;
    execute format('select max(hi::%s)::text from pgpm.part where parent_table = %L::regclass and attached',
                   pgpm._native_type(r.control_kind), r.parent_table::text) into v_new;
    -- preserve-managed incoming FK state: dropped (RI off) vs re-added-but-not-validated (orphan-blocked)
    select count(*) filter (where restored_at is null),
           count(*) filter (where restored_at is not null and validated_at is null)
      into v_fks_susp, v_fks_unval
      from pgpm.dropped_fk where parent_table = r.parent_table;
    -- retain_drop_failures: unexpected DROP failures (issue #238; previously pre_drop hook
    -- failures, before pgpm.hook stopped being consulted here) logged AFTER the last successful
    -- drop, same since-last-progress shape as drain_skips above. Archive coverage not yet complete
    -- is NOT a failure and is never logged here -- it is the normal, expected reason retain_backlog
    -- stays non-zero while chunked archiving catches up (see retain_backlog below).
    select max(id) into v_last_retain_id from pgpm.log
      where parent_table = r.parent_table and action = 'retain_drop';
    -- Exact action values, never a prefix match: `fail_retain_crossing` (issue #268, a live row
    -- references a doomed one and the FK's own ON DELETE refused the delete) and `fail_retain_detach`
    -- (no pgpm_detach cron job to dispatch to) wedge retention exactly as a failed drop does, so they
    -- belong in the same since-last-progress count.
    select count(*) into v_drop_fails from pgpm.log
      where parent_table = r.parent_table
        and action in ('fail_retain_drop', 'fail_retain_crossing', 'fail_retain_detach')
        and id > coalesce(v_last_retain_id, 0);
    -- Partitions whose concurrent detach has been dispatched and not yet completed (issue #268).
    -- Non-zero is normal for a tick or two while cron performs the detach; persistently non-zero with
    -- retain_drop_failures climbing means the dispatch has nowhere to go.
    select count(*) into v_detaching from pgpm.part
      where parent_table = r.parent_table and retiring_at is not null;
    -- retain_backlog: eligible-but-undropped partitions (whole range at/below the retention horizon,
    -- issue #189). Non-zero is normal while retain_batch paces a backlog across ticks, or while
    -- chunked archiving is still catching up on a write-blocked child -- it should fall tick over
    -- tick; flat with retain_drop_failures climbing = wedged on an unexpected drop failure.
    -- null, not 0, for a dead parent: the horizon is derived from the frontier, and the frontier is
    -- max(control) READ FROM THE RELATION. With the relation gone there is no honest answer, and 0 would
    -- read as "nothing is eligible" -- a claim status() cannot make. This is also the one branch that
    -- would raise, via _retain_boundary -> _frontier_native, so skipping it is what keeps status() alive.
    v_retain_backlog := case when v_missing then null else 0 end;
    v_retain_boundary := case when v_missing then null else pgpm._retain_boundary(r) end;
    if v_retain_boundary is not null then
      execute format(
        'select count(*) from pgpm.part where parent_table = %L::regclass and attached and hi::%s <= %L::%s',
        r.parent_table::text, pgpm._native_type(r.control_kind), v_retain_boundary, pgpm._native_type(r.control_kind))
        into v_retain_backlog;
    end if;
    parent := r.parent_table; control_kind := r.control_kind; partition_step := r.partition_step;
    obtain := r.obtain; retain := r.retain; paused := r.paused; n_partitions := v_np;
    coarse_partitions := v_coarse; inflight_partitions := v_inflight; history_unregrained := v_coarse > 0;
    newest_bound := v_new;
    fks_suspended := v_fks_susp; fks_unvalidated := v_fks_unval; retain_drop_failures := v_drop_fails;
    retain_backlog := v_retain_backlog; retain_detaching := v_detaching;
    parent_missing := v_missing;
    return next;
  end loop;
end;
$$;
-- snapshot() removed with the drain (#288). It existed to paper over the drain's VISIBILITY GAP: during a
-- multi-batch drain the already-moved rows lived in an unattached child, so a plain read of the parent
-- undercounted the interval being drained, and snapshot() UNIONed those children back in. regrain never
-- opened that gap (it copies and swaps atomically) and there is no drain, so a read of the parent is
-- never short and there is nothing to union.


-- ===================== observability: pg_flight_recorder correlation =====================
--
-- pgpm.log records exactly when pgpm ran each operation, but pgpm keeps no history of what the
-- rest of the database was doing during it. The optional pg_flight_recorder (PGFR) extension
-- samples that history continuously (wait events, locks, checkpoints, WAL, I/O, query latency) but
-- does not know which spikes were pgpm's. The three functions below bridge the two over a
-- pgpm.log time window. The integration is strictly READ-ONLY and ONE-DIRECTIONAL (pgpm writes
-- nothing into PGFR, and PGFR needs no changes), and PGFR is NEVER a dependency: observe_window
-- works standalone from pure pgpm.log, and the PGFR-delegating functions (impact_report,
-- feathering_validation) raise a clear, catchable error when PGFR is absent rather than failing on
-- a raw "function pgfr_analyze.* does not exist".

-- _observe_has_pgfr: is pg_flight_recorder's analysis layer present? Gates on the pgfr_analyze
-- SCHEMA, not pg_extension: PGFR's script install (the common path) creates the schema and its
-- objects without CREATE EXTENSION; only the dbdev/TLE channel registers an extension. The schema
-- is present either way.
create or replace function pgpm._observe_has_pgfr()
returns boolean language sql stable as $$
  select exists (select 1 from pg_namespace where nspname = 'pgfr_analyze');
$$;

-- observe_window: the span pgpm was active on p_parent within the last p_since, plus a summary of
-- what it did (rows moved, drain/regrain/retain counts, and the adaptive-feathering backoff
-- breakdown by signal). PURE pgpm.log -- no PGFR dependency, so it is useful and testable on its
-- own. Always returns exactly one row; when there is no activity, the window bounds are null and
-- the counts are 0.
--
-- "Operation" actions move data or change structure; the drain_budget rows are the per-tick
-- adaptive decision (method is the OR'd backoff reason: 'probe' = no congestion, else some
-- combination of 'wal'/'lock'/'io').
create or replace function pgpm.observe_window(
  p_parent regclass, p_since interval default '7 days'
) returns table (
  parent_table   regclass,
  window_start   timestamptz,
  window_end     timestamptz,
  duration       interval,
  log_rows       bigint,
  rows_moved     bigint,
  drains         bigint,
  regrains        bigint,
  retains        bigint,
  adaptive_ticks bigint,
  backoffs       bigint,
  wal_backoffs   bigint,
  lock_backoffs  bigint,
  io_backoffs    bigint
) language sql stable as $$
  select
    p_parent,
    min(l.at),
    max(l.at),
    max(l.at) - min(l.at),
    count(*),
    coalesce(sum(l.rows) filter (where l.action in ('drain_move','regrain_copy')), 0),
    count(*) filter (where l.action = 'drain_move'),
    count(*) filter (where l.action = 'regrain'),
    count(*) filter (where l.action = 'retain_drop'),
    count(*) filter (where l.action = 'drain_budget'),
    count(*) filter (where l.action = 'drain_budget' and l.method <> 'probe'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%wal%'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%lock%'),
    count(*) filter (where l.action = 'drain_budget' and l.method like '%io%')
  from pgpm.log l
  where l.parent_table = p_parent
    and l.at >= now() - p_since;
$$;

-- impact_report: "what did my conversion do to the workload?" Derives the active window from
-- pgpm.log (observe_window) and asks pgfr_analyze what the database was doing during it. Sections
-- degrade independently: a section whose PGFR call has too little data (e.g. fewer than two
-- snapshots, or pg_stat_statements reset) reports that rather than failing the whole report.
create or replace function pgpm.impact_report(
  p_parent regclass, p_since interval default '7 days'
) returns text language plpgsql stable as $$
declare
  w        record;
  cmp      record;
  ln       text[] := '{}';
  sect     text;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: impact_report requires pg_flight_recorder (the pgfr_analyze extension). Install it to correlate pgpm operations against database telemetry, or use pgpm.observe_window() for the pgpm-only summary.';
  end if;

  select * into w from pgpm.observe_window(p_parent, p_since);
  if w.window_start is null then
    return format('pg_partition_magician impact report: no pgpm activity for %s in the last %s.', p_parent, p_since);
  end if;

  ln := ln || format('pg_partition_magician :: impact report for %s', p_parent);
  ln := ln || format('  window:   %s  ->  %s  (%s)', w.window_start, w.window_end, w.duration);
  ln := ln || format('  pgpm did: %s log rows, %s rows moved; %s drains, %s regrains, %s retains',
                     w.log_rows, w.rows_moved, w.drains, w.regrains, w.retains);
  ln := ln || format('  feathering: %s adaptive ticks, %s backed off (wal=%s lock=%s io=%s)',
                     w.adaptive_ticks, w.backoffs, w.wal_backoffs, w.lock_backoffs, w.io_backoffs);
  ln := ln || ''::text;

  -- Checkpoints / WAL / temp / I/O over the window (pgfr_analyze.compare brackets
  -- the window with the nearest snapshots and returns the deltas).
  begin
    select * into cmp from pgfr_analyze.compare(w.window_start, w.window_end);
    if not found then   -- FOUND, not "cmp is null": a record with any null field is neither IS NULL nor IS NOT NULL
      ln := ln || '  database impact: insufficient snapshots in the window (need at least two).'::text;
    else
      ln := ln || format('  forced checkpoints: %s (timed: %s)', cmp.ckpt_requested_delta, cmp.ckpt_timed_delta);
      ln := ln || format('  WAL generated:      %s', cmp.wal_bytes_pretty);
      ln := ln || format('  temp spilled:       %s', cmp.temp_bytes_pretty);
      ln := ln || format('  client read time:   %s ms', round(coalesce(cmp.io_client_read_time_ms, 0), 1));
    end if;
  exception when others then
    ln := ln || format('  database impact: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top wait events in the window.
  begin
    sect := '';
    for cmp in
      select wait_event_type, wait_event, total_waiters, pct_of_samples
        from pgfr_analyze.wait_summary(w.window_start, w.window_end)
       where wait_event is not null
       order by total_waiters desc nulls last
       limit 5
    loop
      sect := sect || format('    %-28s waiters=%s  (%s%% of samples)' || chr(10),
                             cmp.wait_event_type || '/' || cmp.wait_event, cmp.total_waiters, round(cmp.pct_of_samples, 1));
    end loop;
    ln := ln || 'top wait events:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none sampled)');
  exception when others then
    ln := ln || format('top wait events: unavailable (%s)', left(sqlerrm, 120));
  end;
  ln := ln || ''::text;

  -- Top queries by execution-time delta in the window.
  begin
    sect := '';
    for cmp in
      select queryid, calls_delta, round(total_exec_time_delta_ms::numeric, 1) as exec_ms
        from pgfr_analyze.statement_activity_v2(w.window_start, w.window_end, 5)
       order by total_exec_time_delta_ms desc nulls last
    loop
      sect := sect || format('    queryid=%-22s calls=%s  exec=%s ms' || chr(10), cmp.queryid, cmp.calls_delta, cmp.exec_ms);
    end loop;
    ln := ln || 'top queries by exec-time:'::text;
    ln := ln || coalesce(nullif(rtrim(sect, chr(10)), ''), '    (none; pg_stat_statements may be absent)');
  exception when others then
    ln := ln || format('top queries by exec-time: unavailable (%s)', left(sqlerrm, 120));
  end;

  return array_to_string(ln, chr(10));
end $$;

-- feathering_validation: ground-truth check on the adaptive feathering. pgpm backs off on its OWN
-- instantaneous reads of WAL rate / lock waiters / I/O latency and discards the raw values. PGFR
-- sampled the same signals independently. For each backoff tick (a drain_budget row whose reason
-- is not 'probe'), this asks PGFR whether real pressure was present in the lead-up window, so you
-- can tell whether the feathering fires for real reasons or phantoms -- ground truth for tuning
-- drain_batch / drain_wal_high_water / the ambient factors.
--
-- Corroboration is the strongest signal PGFR can supply per dimension:
--   wal  -> a forced checkpoint actually occurred in the lead-up (ckpt_requested_delta > 0)
--   lock -> PGFR sampled a Lock wait_event with waiters in the lead-up
--   io   -> client read time was non-zero in the lead-up (null where pg_stat_io is
--           unavailable, e.g. PG15)
-- p_lead is how far back from each tick to look (the backoff is a leading signal, so the pressure
-- precedes the tick). NOTE the lock dimension relies on PGFR's activity ring buffer (~2h retention
-- by default), so lock corroboration is only meaningful for ticks within that window; wal/io come
-- from the 30-day snapshot tier.
create or replace function pgpm.feathering_validation(
  p_parent regclass, p_since interval default '7 days', p_lead interval default '2 minutes'
) returns table (
  tick_at              timestamptz,
  reason               text,
  wal_signal_confirmed boolean,
  lock_signal_confirmed boolean,
  io_signal_confirmed  boolean,
  note                 text
) language plpgsql stable as $$
declare
  r           record;
  cmp         record;
  lk          bigint;
  v_have_cmp  boolean;
begin
  if not pgpm._observe_has_pgfr() then
    raise exception 'pg_partition_magician: feathering_validation requires pg_flight_recorder (the pgfr_analyze extension).';
  end if;

  for r in
    select l.at as tick_at, l.method as reason
      from pgpm.log l
     where l.parent_table = p_parent
       and l.action = 'drain_budget'
       and l.method <> 'probe'
       and l.at >= now() - p_since
     order by l.at
  loop
    -- checkpoints / WAL / I/O in the lead-up window
    begin
      select * into cmp from pgfr_analyze.compare(r.tick_at - p_lead, r.tick_at);
      v_have_cmp := found;          -- FOUND, not "cmp is null": compare's record has null fields (e.g. io_* on PG15)
    exception when others then v_have_cmp := false;
    end;
    -- a Lock wait sampled with waiters in the lead-up window
    begin
      select coalesce(sum(total_waiters), 0) into lk
        from pgfr_analyze.wait_summary(r.tick_at - p_lead, r.tick_at)
       where wait_event_type = 'Lock';
    exception when others then lk := null;
    end;

    tick_at               := r.tick_at;
    reason                := r.reason;
    wal_signal_confirmed  := case when not v_have_cmp then null else coalesce(cmp.ckpt_requested_delta, 0) > 0 end;
    lock_signal_confirmed := case when lk is null then null else lk > 0 end;
    io_signal_confirmed   := case when not v_have_cmp or cmp.io_client_read_time_ms is null then null
                                  else cmp.io_client_read_time_ms > 0 end;
    note := concat_ws('; ',
              case when v_have_cmp then format('ckpt_req=%s wal=%s io_ms=%s',
                     cmp.ckpt_requested_delta, cmp.wal_bytes_pretty, round(coalesce(cmp.io_client_read_time_ms,0),1)) end,
              case when lk is not null then format('lock_waiters=%s', lk) end);
    return next;
  end loop;
end $$;

-- restore_incoming_fks(): re-add the incoming FKs that transmute(..., p_incoming_fks => 'preserve')
-- recorded, pointing them back at the new partitioned parent, but only once it is SAFE. Safe = no
-- in-flight, not-yet-attached child partition exists. (The drained-closed-tail gate this used to carry
-- went with the DEFAULT in #288: there is no tail to drain.) A referenced row inside such a child is
-- outside the visible parent, which a live NO ACTION FK would reject and a CASCADE/SET NULL one would
-- silently honour, so the FK must stay dropped until the child is attached.
-- The re-add is split (issue #95): `ADD CONSTRAINT ... NOT VALID` (enforces every new write, always
-- succeeds) committed separately from `VALIDATE` (scans existing rows, may fail on an orphan written
-- during the suspend window). A failed VALIDATE leaves the FK NOT VALID -- enforcing new writes,
-- surfaced via status().fks_unvalidated -- rather than rolling the re-add back into a permanent silent
-- brick. Returns the number re-added; 0 (a no-op) while a regrain copy-child is still unattached, so
-- `maintain` can call it every tick and it acts only when the table is ready.
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

  -- gate 1 (the drained-closed-tail gate) is gone with the DEFAULT (#288): there is no tail to drain.
  -- gate 2: no in-flight (un-attached) child mid-regrain (same shape as transmute's orphan guard). A
  -- regrain copy-child is EXCLUDED (its range is contained in an attached partition): regrain copies without
  -- deleting, so the referenced rows never leave the visible parent, and a copy-regrain never needs the FK
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
     and not exists (                                            -- a regrain copy is not an absent-row child
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
  -- FK comes back at the first opportunity and can never be permanently bricked by an orphan
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
        values (p_parent, 'fail_restore_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
    end;
    -- The VALIDATE deliberately does NOT happen here (#265). It used to, in its own subtransaction, which
    -- isolated its errors but not its locks: the ADD above takes SHARE ROW EXCLUSIVE on BOTH the
    -- referencing table and the MANAGED PARENT, and a subtransaction releases nothing, so that lock was
    -- held across an O(referencing table) scan. SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so
    -- writes to the parent -- the table pgpm exists to keep online -- blocked for the whole scan.
    -- Measured at 224 ms against 4M referencing rows, and linear.
    --
    -- Splitting them by COMMITting here is not available: this function is also called by regrain_step
    -- mid-swap, and regrain_step is a FUNCTION whose driver regrain() loops it in ONE transaction,
    -- atomic and gap-free. Converting this to a committing procedure would cascade into breaking that.
    --
    -- So the FK is left NOT VALID, which already enforces every NEW write, and maintain() validates it on
    -- a later tick in its own transaction -- where the VALIDATE holds only SHARE UPDATE EXCLUSIVE on the
    -- referencing table and ROW SHARE on the parent, neither of which blocks writes.
  end loop;
  return v_n;
end;
$$;

-- validate_incoming_fks(): finish validating any preserve-managed FK that was re-added NOT VALID but
-- not yet validated (its pre-existing orphans blocked it). Run after clearing the orphans
-- (pgpm.incoming_fk_orphans() lists the counts). Each VALIDATE is isolated, so one still-blocked FK
-- does not stop the others; returns the number newly validated.
--
-- maintain() calls this on a later tick with p_respect_backoff => true, which is what completes the
-- validation without operator action now that restore_incoming_fks deliberately stops at NOT VALID
-- (#265). The back-off is what makes that safe: a FAILING validate re-scans the referencing table to
-- discover it still cannot succeed, so a failure parks it for five minutes instead of burning that scan
-- every tick. A successful one sets validated_at and is never revisited.
--
-- Called directly by an operator it ignores the back-off, since the point of running it by hand is that
-- the orphans have just been cleared and the answer should be immediate.
create or replace function pgpm.validate_incoming_fks(
  p_parent regclass, p_respect_backoff boolean default false
)
returns int language plpgsql as $$
declare r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  for r in select * from pgpm.dropped_fk
            where parent_table = p_parent and restored_at is not null and validated_at is null
              and (not p_respect_backoff
                   or coalesce(validate_retry_after, '-infinity'::timestamptz) <= clock_timestamp())
            order by id loop
    begin
      execute format('alter table %s validate constraint %I', r.referencing_table::text, r.constraint_name);
      update pgpm.dropped_fk set validated_at = now(), validate_retry_after = null where id = r.id;
      insert into pgpm.log (parent_table, action, method) values (p_parent, 'validate_incoming_fk', r.constraint_name);
      v_n := v_n + 1;
    exception when others then
      -- A failed VALIDATE re-scanned the referencing table to get here. Wait before doing that again
      -- (#265); the orphans blocking it are cleared by hand, so a tight retry only burns I/O.
      update pgpm.dropped_fk set validate_retry_after = clock_timestamp() + interval '5 minutes'
        where id = r.id;
      insert into pgpm.log (parent_table, action, method)
        values (p_parent, 'fail_validate_incoming_fk', left(r.constraint_name || ': ' || sqlerrm, 200));
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

-- KEPT, with a much narrower remit after #288. It used to be called by maintain before every drain,
-- dropping the FK for the whole span of a multi-tick drain campaign -- an RI window other sessions could
-- observe, and pgpm's only one. That caller is gone with the drain. The remaining caller is regrain's
-- SWAP, which suspends and restores INSIDE its own transaction, so no session ever observes RI off.
-- suspend_incoming_fks(): the inverse of restore. Re-drop any preserve-managed FK that is currently live,
-- so a referenced row is never taken out of the visible parent past a live FK. That matters beyond a mere
-- stall: a live ON DELETE CASCADE / SET NULL FK would silently delete or null the referencing rows as
-- their referent leaves the parent (verified on PG 17), which is why regrain's swap drops and re-adds
-- inside one transaction rather than relying on the DETACH being brief.
-- p_force is what regrain's swap passes, since a copy-regrain has no pending work of its own to detect.
create or replace function pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false)
returns int language plpgsql as $$
declare v_closed bigint; r pgpm.dropped_fk%rowtype; v_n int := 0;
begin
  if not exists (select 1 from pgpm.dropped_fk
                  where parent_table = p_parent and restored_at is not null) then
    return 0;
  end if;
  -- The drain-work gate is gone with the DEFAULT (#288). regrain's swap is the only caller left and it
  -- always passes p_force, so a call with p_force false has no work to justify it and does nothing.
  if not p_force then return 0; end if;
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
