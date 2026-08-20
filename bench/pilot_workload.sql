-- Synthetic frontier workload for pilot rung 0b (docs/pilot.md): a writer inserting at the write
-- frontier and a reader on the hot end, both against a CUSTOMER's table rather than a bench fixture.
--
-- WHY THIS EXISTS. An idle clone establishes that a conversion is correct. It cannot establish that the
-- conversion is ONLINE, because "no reader or writer was blocked" is trivially true where there are
-- none. Rung 0b supplies the readers and writers that make that assertion mean something, and
-- bench/transmute_online.sh measures it.
--
-- WHY IT GENERATES ITSELF. bench/workload.pgbench calls bench.workload_step(), which only works against
-- the bench schema. A customer table has its own columns, NOT NULLs, foreign keys, checks and identity
-- columns, so the insert has to be derived from the catalog. The row is built by COPYING an existing row
-- with the control column overridden: every NOT NULL, FK and CHECK is then satisfied by construction,
-- because the template row already satisfies them.
--
-- Install with:  \i bench/pilot_workload.sql   then   call pgpm_probe.install('public.events','created_at');
-- Everything lives in schema pgpm_probe; `drop schema pgpm_probe cascade` removes all of it.

create schema if not exists pgpm_probe;

-- One row per committed workload transaction. Written in the SAME transaction as the insert it reports,
-- so a committed log row is evidence the insert committed too. That is what lets transmute_online.sh
-- assert writes actually landed DURING the conversion window instead of assuming they did.
create table if not exists pgpm_probe.workload_log (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default clock_timestamp(),
  inserted      int         not null,
  failed        int         not null,
  last_sqlstate text
);

create table if not exists pgpm_probe.meta (k text primary key, v text not null);

-- A uuidv7 VALUE generator. pgpm._ts_to_uuid zero-fills the tail because it encodes partition BOUNDS,
-- so two calls in the same millisecond return the same uuid and would collide on a primary key. This
-- keeps the 48-bit millisecond prefix that the uuidv7 grid reads, and randomises the rest.
-- gen_random_uuid() is built in (PG13+), so this needs no extension.
create or replace function pgpm_probe.uuidv7_now() returns uuid language sql volatile as $$
  select (lpad(to_hex(floor(extract(epoch from clock_timestamp()) * 1000)::bigint), 12, '0')
          || '7' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 3)
          || '8' || substr(replace(gen_random_uuid()::text, '-', ''), 4, 15))::uuid
$$;

-- Generate pgpm_probe.step() for one specific table + control column.
create or replace procedure pgpm_probe.install(
  p_table      regclass,
  p_control    name,
  p_insert_sql text default null,   -- override the generated INSERT entirely
  p_read_sql   text default null    -- override the generated read
) language plpgsql as $$
declare
  v_kind      text;
  v_ctype     text;
  v_frontier  text;
  v_cols      text[] := '{}';
  v_vals      text[] := '{}';
  v_pk        name[];
  v_insert    text;
  v_read      text;
  r           record;
  v_seq_start numeric;
  v_sur_start numeric;
begin
  -- Drop the previous step() FIRST. If anything below fails, there must be nothing left to run:
  -- a surviving step() from an earlier install points at a DIFFERENT table, and a workload driving the
  -- wrong table looks exactly like a workload driving the right one. Observed while writing this.
  drop function if exists pgpm_probe.step();
  delete from pgpm_probe.meta;

  select format_type(a.atttypid, a.atttypmod) into v_ctype
    from pg_attribute a
   where a.attrelid = p_table and a.attname = p_control and a.attnum > 0 and not a.attisdropped;
  if v_ctype is null then
    raise exception 'pgpm_probe: %.% does not exist', p_table::text, p_control;
  end if;

  -- Same kind mapping the engine uses, so the workload writes where obtain expects the frontier to be.
  v_kind := case
    when v_ctype like 'timestamp%' or v_ctype = 'date' then 'time'
    when v_ctype = 'uuid'                              then 'uuidv7'
    when v_ctype in ('smallint','integer','bigint') or v_ctype like 'numeric%' then 'id'
    else null end;
  if v_kind is null then
    raise exception 'pgpm_probe: control column %.% is %, which is not a pgpm control type',
      p_table::text, p_control, v_ctype;
  end if;

  select array_agg(a.attname order by k.ord) into v_pk
    from pg_index i
    join unnest(i.indkey) with ordinality k(attnum, ord) on true
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
   where i.indrelid = p_table and i.indisprimary;

  -- The frontier value for a new row, per kind. For `id` a dedicated sequence both guarantees
  -- uniqueness under concurrency and advances the frontier monotonically, which max(col)+1 would not:
  -- concurrent clients all read the same max and collide.
  if v_kind = 'id' then
    execute format('select coalesce(max(%I), 0) + 1 from %s', p_control, p_table::text) into v_seq_start;
    if v_seq_start > 9223372036854775807 then
      raise exception 'pgpm_probe: %.% already exceeds bigint, which a sequence cannot express; pass '
        'p_insert_sql with your own value source', p_table::text, p_control;
    end if;
    execute 'create sequence if not exists pgpm_probe.frontier_seq as bigint';
    execute format('select setval(''pgpm_probe.frontier_seq'', %s)', greatest(v_seq_start, 1)::text);
    v_frontier := 'nextval(''pgpm_probe.frontier_seq'')';
  elsif v_kind = 'uuidv7' then
    v_frontier := 'pgpm_probe.uuidv7_now()';
  else
    v_frontier := 'clock_timestamp()';
  end if;

  -- Build the column list. Identity and GENERATED ALWAYS columns are omitted so their defaults fire,
  -- which is also what keeps a copied row from colliding on a surrogate key.
  for r in
    select a.attname, a.attidentity, a.attgenerated,
           format_type(a.atttypid, a.atttypmod) as typ, a.atthasdef
      from pg_attribute a
     where a.attrelid = p_table and a.attnum > 0 and not a.attisdropped
     order by a.attnum
  loop
    if r.attgenerated <> '' or r.attidentity <> '' then
      continue;                                   -- generated / identity: let the default fire
    elsif r.attname = p_control then
      v_cols := v_cols || r.attname;  v_vals := v_vals || v_frontier;
    elsif v_pk is not null and r.attname = any(v_pk) then
      -- A primary-key column that is neither the control column nor defaulted: copying it verbatim
      -- would collide on the very first insert. Integers can come from the probe sequence; anything
      -- else needs the operator, because guessing a unique value for an arbitrary type is not
      -- something this should do silently.
      if r.typ in ('smallint','integer','bigint') or r.typ like 'numeric%' then
        execute format('select coalesce(max(%I), 0) + 1 from %s', r.attname, p_table::text)
          into v_sur_start;
        execute 'create sequence if not exists pgpm_probe.surrogate_seq as bigint';
        execute format('select setval(''pgpm_probe.surrogate_seq'', %s)',
                       greatest(v_sur_start, 1)::text);
        v_cols := v_cols || r.attname;
        v_vals := v_vals || 'nextval(''pgpm_probe.surrogate_seq'')';
      elsif r.atthasdef then
        continue;
      else
        raise exception 'pgpm_probe: primary-key column %.% is % and has no default, so a copied row '
          'would collide. Pass p_insert_sql with an INSERT that supplies it.',
          p_table::text, r.attname, r.typ;
      end if;
    else
      v_cols := v_cols || r.attname;
      v_vals := v_vals || format('t.%I', r.attname);
    end if;
  end loop;

  -- INSERT ... SELECT from the newest existing row: NOT NULLs, FKs and CHECKs hold by construction.
  v_insert := coalesce(p_insert_sql, format(
    'insert into %s (%s) select %s from %s t order by t.%I desc limit 1',
    p_table::text,
    (select string_agg(quote_ident(c), ', ') from unnest(v_cols) c),
    array_to_string(v_vals, ', '),
    p_table::text, p_control));

  v_read := coalesce(p_read_sql,
    format('select 1 from %s order by %I desc limit 1', p_table::text, p_control));

  -- Prove the generated INSERT actually works before handing it to a workload, then undo it. This is
  -- also what catches a copied row colliding on a UNIQUE constraint other than the primary key, which
  -- the column classification above deliberately does not try to reason about. A
  -- generated statement that fails at run time would show up as "the writer was blocked", which is the
  -- one conclusion this whole apparatus exists to draw, so it must not be reachable by a typo.
  begin
    execute v_insert;
    raise exception 'pgpm_probe_dry_run_ok' using errcode = 'P0001';
  exception
    when raise_exception then
      if sqlerrm <> 'pgpm_probe_dry_run_ok' then
        raise exception 'pgpm_probe: the generated INSERT failed its dry run: % %', sqlstate, sqlerrm
          using hint = 'statement was: ' || v_insert;
      end if;
    when others then
      raise exception 'pgpm_probe: the generated INSERT failed its dry run: % %', sqlstate, sqlerrm
        using hint = 'statement was: ' || v_insert;
  end;

  -- ONE insert and ONE read per call, deliberately, and NOT a batch like bench/workload.pgbench.
  -- Locks are held to transaction end, so a step that wrote N rows would hold ROW EXCLUSIVE across all
  -- of them; transmute's ACCESS EXCLUSIVE request would queue behind it and every later reader would
  -- queue behind that. The workload would then be starving the very conversion it is supposed to be
  -- competing with, and the probe would measure the harness instead of the product.
  execute format($f$
    create or replace function pgpm_probe.step() returns void language plpgsql as $body$
    declare ok int := 0; bad int := 0; ss text := null;
    begin
      begin
        %s;
        ok := 1;
      exception when others then bad := bad + 1; ss := sqlstate;
      end;
      begin
        perform %s;
      exception when others then bad := bad + 1; ss := sqlstate;
      end;
      insert into pgpm_probe.workload_log (inserted, failed, last_sqlstate) values (ok, bad, ss);
    end
    $body$;
  $f$, v_insert, '(' || v_read || ')');

  insert into pgpm_probe.meta (k, v) values
    ('table', p_table::text), ('control', p_control), ('kind', v_kind), ('insert', v_insert), ('read', v_read)
  on conflict (k) do update set v = excluded.v;

  raise notice 'pgpm_probe: workload ready for % (% kind)', p_table::text, v_kind;
  raise notice 'pgpm_probe: insert = %', v_insert;
  raise notice 'pgpm_probe: read   = %', v_read;
end
$$;
