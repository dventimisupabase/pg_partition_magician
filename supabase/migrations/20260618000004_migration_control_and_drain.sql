-- =============================================================================
-- 04. Migration control + drain engine.
--
-- The drain moves historical rows out of the DEFAULT partition into proper
-- monthly partitions in paced microbatches. State lives in a control table so
-- the work is idempotent, resumable, observable, and pausable -- exactly the
-- "well-behaved background maintenance" framing from the design doc.
--
-- A row move is necessarily DELETE + INSERT (Postgres has no metadata-only row
-- move), which produces dead tuples in DEFAULT. The goal is NOT to avoid dead
-- tuples but to keep their production below sustainable cleanup capacity, so we
-- move small batches per step (autovacuum tuning lives in 05).
-- =============================================================================

create schema if not exists partition_migration;

-- Single-row control table. is_paused gates the pg_cron driver (05/07) so that
-- `supabase db reset` does NOT kick off an uncontrollable background drain and
-- so pgTAP tests stay deterministic. Flip it to false to start the live drain.
create table partition_migration.control (
  id         boolean primary key default true,
  is_paused  boolean not null    default true,
  batch_size int     not null    default 5000,
  constraint control_single_row check (id)
);
insert into partition_migration.control (id) values (true);

-- One row per month-window that must be drained out of DEFAULT.
create table partition_migration.windows (
  window_start  date primary key,
  window_end    date not null,
  staging_table text not null,
  state         text not null default 'pending'
                check (state in ('pending', 'draining', 'attached')),
  rows_moved    bigint not null default 0,
  started_at    timestamptz,
  last_batch_at timestamptz,
  attached_at   timestamptz
);

-- ---------------------------------------------------------------------------
-- bootstrap_windows(): enumerate the month-windows present in DEFAULT.
-- ---------------------------------------------------------------------------
create or replace function partition_migration.bootstrap_windows()
returns int
language plpgsql
as $$
declare
  v_min date;
  v_max date;
  m     date;
  cnt   int := 0;
begin
  select date_trunc('month', min(created_at))::date,
         date_trunc('month', max(created_at))::date
    into v_min, v_max
    from public.messages_default;

  if v_min is null then
    return 0;  -- DEFAULT is empty; nothing to migrate
  end if;

  m := v_min;
  while m <= v_max loop
    insert into partition_migration.windows (window_start, window_end, staging_table)
    values (m, (m + interval '1 month')::date, 'messages_' || to_char(m, 'YYYY_MM'))
    on conflict (window_start) do nothing;
    m   := (m + interval '1 month')::date;
    cnt := cnt + 1;
  end loop;

  return cnt;
end;
$$;

-- ---------------------------------------------------------------------------
-- _ensure_staging(): create a standalone target table for a window, with a
-- CHECK matching the range (lets ATTACH skip scanning the staging table) and a
-- (created_at, id) unique index matching the parent PK.
-- ---------------------------------------------------------------------------
create or replace function partition_migration._ensure_staging(
  p_lo date, p_hi date, p_part text
)
returns void
language plpgsql
as $$
begin
  if to_regclass('public.' || quote_ident(p_part)) is not null then
    return;
  end if;

  execute format($f$
    create table public.%I (
      id         bigint      not null,
      tenant_id  uuid        not null,
      created_at timestamptz not null,
      body       text        not null,
      constraint %I check (created_at >= %L and created_at < %L)
    )
  $f$, p_part, p_part || '_ck', p_lo, p_hi);

  -- required to satisfy the parent's (created_at, id) primary key on ATTACH
  execute format('create unique index on public.%I (created_at, id)', p_part);
  -- match the parent lookup index so the partition is efficiently queryable
  execute format('create index on public.%I (tenant_id, created_at desc)', p_part);
end;
$$;

-- ---------------------------------------------------------------------------
-- _drain_one_batch(): the unit of work. Promotes the next window if needed,
-- moves one microbatch DEFAULT -> staging, and ATTACHes the staging table once
-- DEFAULT holds no more rows in that window. Returns a short status string.
-- Windows are processed newest-first (design doc: drain recent data first).
-- ---------------------------------------------------------------------------
create or replace function partition_migration._drain_one_batch(p_batch int default 5000)
returns text
language plpgsql
as $$
declare
  w         partition_migration.windows%rowtype;
  v_moved   bigint;
  v_remain  bigint;
begin
  -- Continue an in-flight window, else promote the newest pending one.
  select * into w from partition_migration.windows
   where state = 'draining' order by window_start desc limit 1;

  if not found then
    select * into w from partition_migration.windows
     where state = 'pending' order by window_start desc limit 1;
    if not found then
      return 'idle';  -- migration complete
    end if;
    perform partition_migration._ensure_staging(w.window_start, w.window_end, w.staging_table);
    update partition_migration.windows
       set state = 'draining', started_at = now()
     where window_start = w.window_start;
  end if;

  -- Move one microbatch. ctid + LIMIT keeps each delete bounded and WAL small.
  execute format($f$
    with batch as (
      delete from public.messages_default
       where ctid in (
         select ctid from public.messages_default
          where created_at >= %L and created_at < %L
          order by created_at
          limit %s
       )
      returning id, tenant_id, created_at, body
    )
    insert into public.%I (id, tenant_id, created_at, body)
    select id, tenant_id, created_at, body from batch
  $f$, w.window_start, w.window_end, p_batch, w.staging_table);
  get diagnostics v_moved = row_count;

  update partition_migration.windows
     set rows_moved = rows_moved + v_moved, last_batch_at = now()
   where window_start = w.window_start;

  -- When DEFAULT has no more rows in this window, attach the staging table.
  -- The CHECK proves staging rows are in range (no staging scan); DEFAULT is
  -- still briefly scanned under ACCESS EXCLUSIVE -- the real locking cost.
  execute format(
    'select count(*) from public.messages_default where created_at >= %L and created_at < %L',
    w.window_start, w.window_end
  ) into v_remain;

  if v_remain = 0 then
    execute format(
      'alter table public.messages attach partition public.%I for values from (%L) to (%L)',
      w.staging_table, w.window_start, w.window_end
    );
    update partition_migration.windows
       set state = 'attached', attached_at = now()
     where window_start = w.window_start;
    return 'attached:' || w.staging_table;
  end if;

  return 'moved:' || v_moved;
end;
$$;

-- ---------------------------------------------------------------------------
-- drain_step(): the procedure pg_cron CALLs. Respects the pause flag so the
-- scheduled job is a no-op until the operator opts in.
-- ---------------------------------------------------------------------------
create or replace procedure partition_migration.drain_step(p_batch int default null)
language plpgsql
as $$
declare
  c partition_migration.control%rowtype;
begin
  select * into c from partition_migration.control where id;
  if coalesce(c.is_paused, true) then
    return;
  end if;
  perform partition_migration._drain_one_batch(coalesce(p_batch, c.batch_size, 5000));
end;
$$;

-- ---------------------------------------------------------------------------
-- drain_all(): drive the drain to completion synchronously. For tests and
-- manual full runs; ignores the pause flag (explicit operator action).
-- ---------------------------------------------------------------------------
create or replace function partition_migration.drain_all(p_batch int default 5000)
returns int
language plpgsql
as $$
declare
  v_status text;
  v_iter   int := 0;
begin
  loop
    v_status := partition_migration._drain_one_batch(p_batch);
    exit when v_status = 'idle';
    v_iter := v_iter + 1;
    if v_iter > 100000 then
      raise exception 'drain_all exceeded safety iteration limit';
    end if;
  end loop;
  return v_iter;
end;
$$;

-- Enumerate the windows that exist in the freshly-adopted DEFAULT partition.
select partition_migration.bootstrap_windows();
