-- =============================================================================
-- pg_partition_magician  --  a lightweight, pure-SQL time-range partition manager
--
--   * Only runtime dependency: pg_cron (and only for scheduling -- every function
--     can be called by hand). No compiled extension, no superuser needed beyond
--     what running this script requires. Install with: psql -f this_file.sql
--   * Schema: pgpm
--   * Manages the full lifecycle of native RANGE-partitioned tables:
--       adopt()      -- convert an existing (possibly huge, live) table online
--       premake      -- keep N partitions ahead of the write frontier
--       drain        -- move the DEFAULT partition's closed tail into partitions
--       retention    -- drop partitions older than a policy
--       maintenance  -- the single proc pg_cron calls (premake + retention + drain)
--
-- Design notes (see README):
--   * Adding a partition while the DEFAULT holds data forces a full scan of the
--     DEFAULT under ACCESS EXCLUSIVE. We avoid that blocking scan for any range
--     that receives no concurrent writes (closed past intervals + future premake)
--     via: ADD CONSTRAINT ... NOT VALID  ->  VALIDATE (SHARE UPDATE EXCLUSIVE,
--     non-blocking)  ->  CREATE/ATTACH (scan skipped)  ->  DROP CONSTRAINT.
--   * The one rule that keeps this safe: never exclude the interval that is
--     currently receiving writes. It simply lives in the DEFAULT until it closes,
--     then drains as a closed tail. Premake keeps future intervals ready, so live
--     writes always have a real partition (the open window we drain is the tail).
-- =============================================================================

create schema if not exists pgpm;

-- One row per managed partitioned table.
create table if not exists pgpm.config (
  parent_table       regclass    primary key,
  control_column     name        not null,
  partition_interval interval     not null,
  premake            int          not null default 4,
  retention          interval,                 -- null = keep forever
  keep_default       boolean      not null default true,
  drain_batch        int          not null default 5000,
  interval_anchor    timestamptz  not null default '2000-01-01 00:00:00+00',
  default_table      name         not null,    -- name of the DEFAULT partition
  paused             boolean      not null default true,   -- gates automated maintenance
  created_at         timestamptz  not null default now()
);

-- Registry of the partitions we manage (excludes the DEFAULT). Powers retention
-- and the status views without parsing pg_get_expr(relpartbound).
create table if not exists pgpm.part (
  parent_table regclass    not null,
  child_name   name        not null,
  lo           timestamptz not null,
  hi           timestamptz not null,
  created_at   timestamptz not null default now(),
  primary key (parent_table, child_name)
);

-- Audit log of maintenance actions.
create table if not exists pgpm.log (
  id           bigint generated always as identity primary key,
  parent_table regclass,
  action       text,        -- adopt | premake | drain_move | drain_attach | retention_drop
  lo           timestamptz,
  hi           timestamptz,
  method       text,        -- check_skip | plain (for attaches/creates)
  rows         bigint,
  at           timestamptz not null default now()
);

-- Incoming foreign keys dropped by adopt(p_incoming_fks => 'drop'), recorded so
-- they can be reviewed/reconstructed. NOTE: `definition` is the ORIGINAL FK
-- (e.g. single-column); it will NOT recreate as-is against the now-partitioned
-- table -- rebuild it as a composite FK on the partition key (see README).
create table if not exists pgpm.dropped_fk (
  id                bigint generated always as identity primary key,
  parent_table      regclass    not null,
  referencing_table regclass    not null,
  constraint_name   name        not null,
  definition        text        not null,
  dropped_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- _lo(): floor a timestamp to the partition-grid lower bound for an interval.
-- Supports whole-month intervals (1/3/12 months, ...) and fixed-duration
-- intervals (hours/days/weeks). Mixed month+duration intervals are rejected.
-- ---------------------------------------------------------------------------
create or replace function pgpm._lo(p_interval interval, p_anchor timestamptz, p_ts timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_months int             := (extract(year from p_interval) * 12 + extract(month from p_interval))::int;
  v_fixsecs double precision := extract(epoch from (p_interval - make_interval(months => v_months)));
  v_secs   double precision := extract(epoch from p_interval);
  k        bigint;
begin
  if v_months > 0 then
    if v_fixsecs <> 0 then
      raise exception 'pg_partition_magician: mixed month + duration intervals are unsupported (got %)', p_interval;
    end if;
    k := ((extract(year from p_ts) - extract(year from p_anchor)) * 12
        + (extract(month from p_ts) - extract(month from p_anchor)))::bigint;
    k := (floor(k::numeric / v_months) * v_months)::bigint;
    return date_trunc('month', p_anchor) + make_interval(months => k::int);
  else
    k := floor(extract(epoch from (p_ts - p_anchor)) / v_secs)::bigint;
    return p_anchor + make_interval(secs => k * v_secs);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- _part_name(): deterministic partition name, granularity-appropriate suffix.
-- ---------------------------------------------------------------------------
create or replace function pgpm._part_name(p_relname name, p_interval interval, p_lo timestamptz)
returns name
language plpgsql stable
as $$
declare
  v_months int             := (extract(year from p_interval) * 12 + extract(month from p_interval))::int;
  v_secs   double precision := extract(epoch from p_interval);
  fmt      text;
begin
  if    v_months >= 12 and v_months % 12 = 0 then fmt := 'YYYY';
  elsif v_months > 0                          then fmt := 'YYYY_MM';
  elsif v_secs  >= 86400                       then fmt := 'YYYY_MM_DD';
  elsif v_secs  >= 3600                        then fmt := 'YYYY_MM_DD_HH24';
  else                                              fmt := 'YYYY_MM_DD_HH24MI';
  end if;
  return (p_relname || '_p' || to_char(p_lo, fmt))::name;
end;
$$;

-- ---------------------------------------------------------------------------
-- _create_partition(): create an EMPTY partition for [lo,hi). Used by premake.
-- Skips the DEFAULT scan (via NOT VALID + VALIDATE) when the default is non-empty.
-- ---------------------------------------------------------------------------
create or replace function pgpm._create_partition(
  p_cfg pgpm.config, p_nsp name, p_rel name, p_default regclass,
  p_name name, p_lo timestamptz, p_hi timestamptz
)
returns void
language plpgsql
as $$
declare
  v_empty  boolean;
  v_excl   name;
  v_method text;
begin
  if p_cfg.keep_default then
    execute format('select not exists (select 1 from %s)', p_default::text) into v_empty;
  else
    v_empty := true;
  end if;

  if v_empty then
    execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                   p_nsp, p_name, p_nsp, p_rel, p_lo, p_hi);
    v_method := 'plain';
  else
    v_excl := (p_name || '_excl')::name;
    execute format('alter table %s add constraint %I check (%I < %L or %I >= %L) not valid',
                   p_default::text, v_excl, p_cfg.control_column, p_lo, p_cfg.control_column, p_hi);
    execute format('alter table %s validate constraint %I', p_default::text, v_excl);
    execute format('create table %I.%I partition of %I.%I for values from (%L) to (%L)',
                   p_nsp, p_name, p_nsp, p_rel, p_lo, p_hi);
    execute format('alter table %s drop constraint %I', p_default::text, v_excl);
    v_method := 'check_skip';
  end if;

  insert into pgpm.part (parent_table, child_name, lo, hi)
    values (format('%I.%I', p_nsp, p_rel)::regclass, p_name, p_lo, p_hi)
    on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method)
    values (format('%I.%I', p_nsp, p_rel)::regclass, 'premake', p_lo, p_hi, v_method);
end;
$$;

-- ---------------------------------------------------------------------------
-- premake(): ensure partitions exist for the current interval and the next
-- `premake` intervals. The current interval is skipped while the DEFAULT still
-- holds its rows (initial migration) -- the drain attaches it once it closes.
-- ---------------------------------------------------------------------------
create or replace function pgpm.premake(p_parent regclass)
returns int
language plpgsql
as $$
declare
  cfg      pgpm.config;
  v_nsp    name;
  v_rel    name;
  v_default regclass;
  v_now_lo timestamptz;
  v_lo     timestamptz;
  v_hi     timestamptz;
  v_name   name;
  v_has    boolean;
  v_made   int := 0;
  k        int;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_default := format('%I.%I', v_nsp, cfg.default_table)::regclass;
  v_now_lo  := pgpm._lo(cfg.partition_interval, cfg.interval_anchor, now());

  for k in 0 .. cfg.premake loop
    v_lo   := pgpm._lo(cfg.partition_interval, cfg.interval_anchor, v_now_lo + cfg.partition_interval * k);
    v_hi   := v_lo + cfg.partition_interval;
    v_name := pgpm._part_name(v_rel, cfg.partition_interval, v_lo);
    continue when to_regclass(format('%I.%I', v_nsp, v_name)) is not null;

    -- Skip a range the DEFAULT still holds data for (only the active interval,
    -- pre-drain): attaching it now would be the open-window case.
    execute format('select exists (select 1 from %s where %I >= %L and %I < %L)',
                   v_default::text, cfg.control_column, v_lo, cfg.control_column, v_hi) into v_has;
    continue when v_has;

    perform pgpm._create_partition(cfg, v_nsp, v_rel, v_default, v_name, v_lo, v_hi);
    v_made := v_made + 1;
  end loop;
  return v_made;
end;
$$;

-- ---------------------------------------------------------------------------
-- drain_step(): move one microbatch of the oldest interval still in the DEFAULT
-- into a staging table; when that interval is empty in the DEFAULT, attach it.
-- Closed intervals attach via the scan-skip path; the open (current) interval is
-- only touched when p_include_open is true, and then via a write-safe plain
-- ATTACH (a NOT VALID CHECK would reject live writes routing to the default).
-- Returns 'idle' | 'moved:N' | 'attached:<name>:<method>'.
-- ---------------------------------------------------------------------------
create or replace function pgpm.drain_step(
  p_parent regclass, p_batch int default null, p_include_open boolean default false
)
returns text
language plpgsql
as $$
declare
  cfg     pgpm.config;
  v_nsp   name;
  v_rel   name;
  v_def   text;
  v_cols  text;
  v_batch int;
  v_min   timestamptz;
  v_lo    timestamptz;
  v_hi    timestamptz;
  v_name  name;
  v_open  boolean;
  v_moved bigint;
  v_remain bigint;
  v_excl  name;
  v_method text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_def   := format('%I.%I', v_nsp, cfg.default_table);
  v_batch := coalesce(p_batch, cfg.drain_batch, 5000);

  execute format('select min(%I) from %s', cfg.control_column, v_def) into v_min;
  if v_min is null then return 'idle'; end if;     -- DEFAULT empty

  v_lo   := pgpm._lo(cfg.partition_interval, cfg.interval_anchor, v_min);
  v_hi   := v_lo + cfg.partition_interval;
  v_open := (v_hi > now());
  if v_open and not p_include_open then
    return 'idle';   -- only the active interval remains; leave it until it closes
  end if;
  v_name := pgpm._part_name(v_rel, cfg.partition_interval, v_lo);

  -- staging table that will BECOME the partition (LIKE parent: gets the PK index)
  if to_regclass(format('%I.%I', v_nsp, v_name)) is null then
    execute format('create table %I.%I (like %I.%I including defaults including indexes including constraints excluding identity)',
                   v_nsp, v_name, v_nsp, v_rel);
    execute format('alter table %I.%I add constraint %I check (%I >= %L and %I < %L)',
                   v_nsp, v_name, (v_name || '_ck'), cfg.control_column, v_lo, cfg.control_column, v_hi);
  end if;

  select string_agg(quote_ident(attname), ', ' order by attnum) into v_cols
    from pg_attribute where attrelid = p_parent and attnum > 0 and not attisdropped;

  -- move one microbatch (ctid + LIMIT keeps each delete bounded; small WAL)
  execute format($f$
    with b as (
      delete from %1$s
       where ctid in (select ctid from %1$s
                       where %2$I >= %3$L and %2$I < %4$L
                       order by %2$I limit %5$s)
      returning %6$s
    )
    insert into %7$I.%8$I (%6$s) select %6$s from b
  $f$, v_def, cfg.control_column, v_lo, v_hi, v_batch, v_cols, v_nsp, v_name);
  get diagnostics v_moved = row_count;
  insert into pgpm.log (parent_table, action, lo, hi, rows) values (p_parent, 'drain_move', v_lo, v_hi, v_moved);

  execute format('select count(*) from %s where %I >= %L and %I < %L',
                 v_def, cfg.control_column, v_lo, cfg.control_column, v_hi) into v_remain;
  if v_remain > 0 then
    return 'moved:' || v_moved;
  end if;

  -- interval fully out of the DEFAULT -> attach the staging table
  if v_open or not cfg.keep_default then
    execute format('alter table %I.%I attach partition %I.%I for values from (%L) to (%L)',
                   v_nsp, v_rel, v_nsp, v_name, v_lo, v_hi);
    v_method := 'plain';
  else
    v_excl := (v_name || '_excl')::name;
    execute format('alter table %s add constraint %I check (%I < %L or %I >= %L) not valid',
                   v_def, v_excl, cfg.control_column, v_lo, cfg.control_column, v_hi);
    execute format('alter table %s validate constraint %I', v_def, v_excl);
    execute format('alter table %I.%I attach partition %I.%I for values from (%L) to (%L)',
                   v_nsp, v_rel, v_nsp, v_name, v_lo, v_hi);
    execute format('alter table %s drop constraint %I', v_def, v_excl);
    v_method := 'check_skip';
  end if;

  insert into pgpm.part (parent_table, child_name, lo, hi) values (p_parent, v_name, v_lo, v_hi)
    on conflict do nothing;
  insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'drain_attach', v_lo, v_hi, v_method);
  return 'attached:' || v_name || ':' || v_method;
end;
$$;

-- drain_all(): drive the drain to completion (closed intervals; optionally the
-- open one too via plain attach). Ignores the pause flag -- explicit operator call.
create or replace function pgpm.drain_all(
  p_parent regclass, p_batch int default null, p_include_open boolean default false
)
returns int
language plpgsql
as $$
declare v_status text; v_iter int := 0;
begin
  loop
    v_status := pgpm.drain_step(p_parent, p_batch, p_include_open);
    exit when v_status = 'idle';
    v_iter := v_iter + 1;
    if v_iter > 1000000 then raise exception 'pg_partition_magician: drain_all safety limit'; end if;
  end loop;
  return v_iter;
end;
$$;

-- retention(): drop partitions whose upper bound is older than now() - retention.
-- Plain DROP (brief lock) -- DETACH CONCURRENTLY can't run inside a function.
create or replace function pgpm.retention(p_parent regclass)
returns int
language plpgsql
as $$
declare
  cfg pgpm.config;
  v_nsp name; v_rel name; v_boundary timestamptz; r record; v_dropped int := 0;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.retention is null then return 0; end if;
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_boundary := pgpm._lo(cfg.partition_interval, cfg.interval_anchor, now() - cfg.retention);

  for r in select child_name, lo, hi from pgpm.part
            where parent_table = p_parent and hi <= v_boundary order by lo loop
    execute format('drop table %I.%I', v_nsp, r.child_name);
    delete from pgpm.part where parent_table = p_parent and child_name = r.child_name;
    insert into pgpm.log (parent_table, action, lo, hi, method) values (p_parent, 'retention_drop', r.lo, r.hi, null);
    v_dropped := v_dropped + 1;
  end loop;
  return v_dropped;
end;
$$;

-- ---------------------------------------------------------------------------
-- adopt(): convert an existing (possibly large, live) unpartitioned table into
-- a RANGE-partitioned one online, by attaching it as the DEFAULT partition, then
-- register it and premake the initial future partitions. ZERO data movement here.
-- ---------------------------------------------------------------------------
create or replace function pgpm.adopt(
  p_parent       regclass,
  p_control      name,
  p_interval     interval,
  p_premake      int         default 4,
  p_retention    interval    default null,
  p_keep_default boolean     default true,
  p_drain_batch  int         default 5000,
  p_anchor       timestamptz default '2000-01-01 00:00:00+00',
  p_paused       boolean     default true,
  p_incoming_fks text        default 'error'   -- 'error' | 'drop'
)
returns regclass
language plpgsql
as $$
declare
  v_nsp     name;
  v_rel     name;
  v_default name;
  v_defreg  regclass;
  v_parent  regclass;
  v_oldpk   text[];
  v_pkcols  text[];
  v_idcols  name[];
  v_pkname  name;
  v_col     name;
  v_idx_names text[];
  v_idx_defs  text[];
  v_skipped   int;
  v_old     name;
  v_new     name;
  v_pdef    text;
  j         int;
  v_fk      record;
begin
  select n.nspname, c.relname into v_nsp, v_rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_default := (v_rel || '_default')::name;

  -- existing PK columns (key order), and identity columns
  select array_agg(a.attname::text order by k.ord) into v_oldpk
    from pg_constraint con
    cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
   where con.conrelid = p_parent and con.contype = 'p';
  select conname into v_pkname from pg_constraint where conrelid = p_parent and contype = 'p';
  select array_agg(a.attname order by a.attnum) into v_idcols
    from pg_attribute a where a.attrelid = p_parent and a.attidentity in ('a','d') and not a.attisdropped;

  -- Capture secondary (non-PK, non-unique) indexes BEFORE the rename, so their
  -- definitions reference the original name (which becomes the parent). They are
  -- recreated as partitioned indexes on the parent below. Unique secondary
  -- indexes are skipped (a partitioned unique index must include the partition
  -- key) -- recreate those by hand if needed.
  select array_agg(c.relname::text), array_agg(pg_get_indexdef(i.indexrelid))
    into v_idx_names, v_idx_defs
    from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p_parent and i.indislive and not i.indisprimary and not i.indisunique;
  select count(*) into v_skipped
    from pg_index i
   where i.indrelid = p_parent and i.indislive and i.indisunique and not i.indisprimary;
  if v_skipped > 0 then
    raise notice 'pg_partition_magician: skipped % unique secondary index(es) on %; recreate on the parent manually (must include the partition key)',
                 v_skipped, p_parent;
  end if;

  if v_oldpk is not null then
    v_pkcols := array[p_control::text] || array(select x from unnest(v_oldpk) x where x <> p_control::text);
  end if;

  -- 0. Incoming foreign keys. A partitioned table's only unique key includes the
  --    partition key, so a single-column FK to this table cannot survive -- and
  --    the old PK can't even be dropped while a dependent FK exists. Handle this
  --    before any mutation so a refusal leaves the table untouched.
  if p_incoming_fks not in ('error', 'drop') then
    raise exception 'pg_partition_magician: p_incoming_fks must be ''error'' or ''drop'' (got %)', p_incoming_fks;
  end if;
  if exists (select 1 from pg_constraint where confrelid = p_parent and contype = 'f') then
    if p_incoming_fks = 'error' then
      raise exception
        'pg_partition_magician: % has incoming foreign key(s) (%); a single-column FK cannot reference a partitioned table. Re-point them as composite FKs on the partition key, or call adopt(..., p_incoming_fks => ''drop'') to drop and record them in pgpm.dropped_fk.',
        p_parent,
        (select string_agg(conname || ' on ' || conrelid::regclass::text, ', ')
           from pg_constraint where confrelid = p_parent and contype = 'f');
    else
      for v_fk in
        select conrelid::regclass as reltbl, conname, pg_get_constraintdef(oid) as def
          from pg_constraint where confrelid = p_parent and contype = 'f'
      loop
        insert into pgpm.dropped_fk (parent_table, referencing_table, constraint_name, definition)
          values (p_parent, v_fk.reltbl, v_fk.conname, v_fk.def);
        execute format('alter table %s drop constraint %I', v_fk.reltbl::text, v_fk.conname);
        insert into pgpm.log (parent_table, action, method) values (p_parent, 'drop_incoming_fk', v_fk.conname::text);
      end loop;
    end if;
  end if;

  -- 1. rename the live table to the DEFAULT partition name (keeps all its data)
  execute format('alter table %s rename to %I', p_parent::text, v_default);
  v_defreg := format('%I.%I', v_nsp, v_default)::regclass;

  -- 2. drop the old (sub-)PK; a partitioned PK must include the partition key
  if v_pkname is not null then
    execute format('alter table %s drop constraint %I', v_defreg::text, v_pkname);
  end if;

  -- 3. identity belongs on the parent; drop it on the default. Ensure the key
  --    columns are NOT NULL.
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

  -- 4. Build the composite unique index on the default and PROMOTE it to the
  --    default's PRIMARY KEY. This index is reused (never rebuilt) when the
  --    parent PK is established below -- the key to an online swap on a huge
  --    table. (Creating the parent WITH a PK and then attaching would instead
  --    rebuild this index on the whole default under ACCESS EXCLUSIVE.)
  if v_pkcols is not null then
    execute format('create unique index %I on %s (%s)',
                   (v_default || '_pk_tmp'), v_defreg::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
    execute format('alter table %s add constraint %I primary key using index %I',
                   v_defreg::text, (v_default || '_pkey'), (v_default || '_pk_tmp'));
  end if;

  -- 5. create the partitioned parent under the original name (no PK yet)
  execute format('create table %I.%I (like %s including defaults including generated) partition by range (%I)',
                 v_nsp, v_rel, v_defreg::text, p_control);
  v_parent := format('%I.%I', v_nsp, v_rel)::regclass;

  -- 6. re-establish identity on the parent for former identity columns
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('alter table %s alter column %I add generated by default as identity', v_parent::text, v_col);
    end loop;
  end if;

  -- 7. attach the existing table as the DEFAULT partition (no rows move; the
  --    parent has no PK yet, so no index build is triggered)
  execute format('alter table %s attach partition %s default', v_parent::text, v_defreg::text);

  -- 8. establish the parent PRIMARY KEY -- reuses the default's promoted PK index
  --    (no rebuild). New/premade partitions build their own (empty) PK index.
  if v_pkcols is not null then
    execute format('alter table %s add primary key (%s)', v_parent::text,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pkcols) x));
  end if;

  -- 8b. advance identity sequences past the largest existing value
  if v_idcols is not null then
    foreach v_col in array v_idcols loop
      execute format('select setval(pg_get_serial_sequence(%L, %L), coalesce((select max(%I) from %s), 0) + 1, false)',
                     v_parent::text, v_col, v_col, v_defreg::text);
    end loop;
  end if;

  -- 9. treat the default as a maintenance workload: keep autovacuum ahead
  execute format('alter table %s set ('
              || 'autovacuum_vacuum_scale_factor = 0.0, autovacuum_vacuum_threshold = 1000, '
              || 'autovacuum_analyze_scale_factor = 0.0, autovacuum_analyze_threshold = 1000, '
              || 'autovacuum_vacuum_cost_limit = 2000, autovacuum_vacuum_cost_delay = 2)', v_defreg::text);

  -- 9b. recreate secondary indexes as PARTITIONED indexes on the parent, then
  --     ATTACH the default's existing index to each (no rebuild of the big
  --     default). New/premade partitions inherit these automatically.
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

  -- 10. register and premake the initial future partitions
  insert into pgpm.config (parent_table, control_column, partition_interval, premake, retention,
                           keep_default, drain_batch, interval_anchor, default_table, paused)
  values (v_parent, p_control, p_interval, p_premake, p_retention,
          p_keep_default, p_drain_batch, p_anchor, v_default, p_paused)
  on conflict (parent_table) do update set
    control_column = excluded.control_column, partition_interval = excluded.partition_interval,
    premake = excluded.premake, retention = excluded.retention, keep_default = excluded.keep_default,
    drain_batch = excluded.drain_batch, interval_anchor = excluded.interval_anchor,
    default_table = excluded.default_table, paused = excluded.paused;

  insert into pgpm.log (parent_table, action, method) values (v_parent, 'adopt', null);
  perform pgpm.premake(v_parent);
  return v_parent;
end;
$$;

-- ---------------------------------------------------------------------------
-- maintenance(): the automated step (premake + retention + one drain batch).
-- Respects the per-table pause flag. Returned text is a short summary.
-- ---------------------------------------------------------------------------
create or replace function pgpm.maintenance(p_parent regclass)
returns text
language plpgsql
as $$
declare cfg pgpm.config; v_made int; v_dropped int; v_drain text;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  if cfg.paused then return 'paused'; end if;
  v_made    := pgpm.premake(p_parent);
  v_dropped := pgpm.retention(p_parent);
  v_drain   := pgpm.drain_step(p_parent);
  return format('premade=%s dropped=%s drain=%s', v_made, v_dropped, v_drain);
end;
$$;

-- maintenance_all(): the single entry point for pg_cron.
create or replace procedure pgpm.maintenance_all()
language plpgsql
as $$
declare r record;
begin
  for r in select parent_table from pgpm.config loop
    perform pgpm.maintenance(r.parent_table);
  end loop;
end;
$$;

-- check_default(): rows still in the DEFAULT, and how many belong to already-
-- closed intervals (i.e. should have drained -- the alert condition).
create or replace function pgpm.check_default(p_parent regclass)
returns table (default_rows bigint, closed_rows bigint, oldest timestamptz)
language plpgsql
as $$
declare cfg pgpm.config; v_nsp name; v_def text; v_cur_lo timestamptz;
begin
  select * into cfg from pgpm.config where parent_table = p_parent;
  if not found then raise exception 'pg_partition_magician: % is not managed', p_parent; end if;
  select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = p_parent;
  v_def    := format('%I.%I', v_nsp, cfg.default_table);
  v_cur_lo := pgpm._lo(cfg.partition_interval, cfg.interval_anchor, now());
  return query execute format(
    'select count(*)::bigint, count(*) filter (where %I < %L)::bigint, min(%I) from %s',
    cfg.control_column, v_cur_lo, cfg.control_column, v_def);
end;
$$;

-- status(): one row per managed table for monitoring.
create or replace function pgpm.status()
returns table (
  parent regclass, control_column name, partition_interval interval, premake int,
  retention interval, paused boolean, n_partitions bigint,
  default_rows bigint, default_oldest timestamptz, newest_bound timestamptz
)
language plpgsql
as $$
declare r pgpm.config; v_nsp name; v_def text; v_drows bigint; v_old timestamptz; v_np bigint; v_new timestamptz;
begin
  for r in select * from pgpm.config loop
    select n.nspname into v_nsp from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r.parent_table;
    v_def := format('%I.%I', v_nsp, r.default_table);
    execute format('select count(*)::bigint, min(%I) from %s', r.control_column, v_def) into v_drows, v_old;
    select count(*), max(hi) into v_np, v_new from pgpm.part where parent_table = r.parent_table;
    parent := r.parent_table; control_column := r.control_column; partition_interval := r.partition_interval;
    premake := r.premake; retention := r.retention; paused := r.paused; n_partitions := v_np;
    default_rows := v_drows; default_oldest := v_old; newest_bound := v_new;
    return next;
  end loop;
end;
$$;

-- Convenience view over the partition registry.
create or replace view pgpm.partitions as
  select parent_table, child_name, lo, hi, created_at from pgpm.part order by parent_table, lo;
