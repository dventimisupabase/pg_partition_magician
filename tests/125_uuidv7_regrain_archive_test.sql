-- Issue #507: PostgreSQL has no max(uuid) or min(uuid) aggregate, and three places read the newest or
-- next control value of a uuidv7 table with exactly those aggregates. regrain_step's copy resumed from
-- `(select max(d2.<control>) from <fine child> d2)`, so every regrain of a uuidv7 monolith raised 42883
-- at its first copy batch: synchronously through pgpm.regrain(), and as a skip_regrain row on every
-- maintain tick once set_regrain had armed auto-regrain, forever, with the capture trigger left on the
-- source. _next_archive_chunk sized a chunk with max(<control>) over the byte-budget window and extended
-- it past a run of ties with min(<control>), so on a uuidv7 table with an archive_fn every tick's archive
-- step raised the same way, was logged as skip_archive, wrote no ledger row, and retain() never dropped
-- the aged partition. _frontier_native had avoided the aggregate for this exact reason since #325
-- ("ORDER BY ... LIMIT 1 (not max()) so it works for uuid too"); the fix reads all three the same way.
--
-- Every negative below ("no skip_regrain", "no skip_archive") is paired with a witness that the step
-- it denies really ran and really did its work, and the outcomes are asserted by identity: the exact
-- set of rows before and after (an md5 over every id and payload, in id order), the exact lower bounds
-- of the partitions that replace the monolith, the exact range the ledger covers and retain_drop names.
--
-- The fixture cannot pin dates the way the issue's own reproductions tried to: on this code a uuidv7
-- monolith's upper bound comes from greatest(max(control), now()), so it always covers now() and is
-- never frozen or aged at conversion time. Instead a row three months ahead, written AFTER conversion
-- into an obtain-created forward partition, moves the frontier past the monolith and freezes it (the
-- same lever the issue's F9-08 reproduction uses), and an aged partition then only exists once the
-- monolith has been regrained into months. bench/uuidv7_regrain_archive.sh runs this file against the
-- mutants in bench/mutations/mutate.py that put each of the three aggregates back.
create extension if not exists pgtap;

select plan(24);
set timezone = 'UTC';

-- ============================================== (A) pgpm.regrain(): the copy's resume point
-- Hourly rows from the start of the month two months back to just before now, with a 100-row copy batch
-- so every month is copied in several batches and the resume watermark is read for real, not just once.
create table public.u7r (id uuid primary key, payload text);
insert into public.u7r (id, payload)
select pgpm._ts_to_uuid(ts), 'r' || row_number() over (order by ts)
  from generate_series(date_trunc('month', now()) - interval '2 months',
                       now() - interval '1 minute', interval '1 hour') ts;
call pgpm.transmute('public.u7r', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_regrain_batch => 100);
select pgpm.obtain('public.u7r');
-- a write three months ahead lands in a forward partition and moves the frontier past the monolith
insert into public.u7r (id, payload)
  values (pgpm._ts_to_uuid(date_trunc('month', now()) + interval '3 months 1 day'), 'frontier');

select child_name as mono_r from pgpm.part
 where parent_table = 'public.u7r'::regclass and attached order by lo::timestamptz limit 1 \gset
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_r_before from public.u7r \gset
select count(*) as n_r_hist from public.u7r
 where pgpm._uuid_to_ts(id) < date_trunc('month', now()) + interval '1 month' \gset

select is((select hi::timestamptz from pgpm.part
            where parent_table = 'public.u7r'::regclass and child_name = :'mono_r'),
          date_trunc('month', now()) + interval '1 month',
          'LIVENESS: the monolith ends at the start of next month, so it spans three whole months');
select is(pgpm.regrain_step('public.u7r', :'mono_r', '1 month', 100), 'prepared',
          'LIVENESS: the monolith is frozen and subdividable, so regrain_step prepares it');

-- the archive chunk sizer, read directly on this frozen, row-bearing monolith: the whole thing fits one
-- 8 MB chunk, so the chunk it returns must be exactly the monolith's own range
select lives_ok(format('select * from pgpm._next_archive_chunk(%L, %L)', 'public.u7r', :'mono_r'),
                '_next_archive_chunk sizes a chunk of a uuidv7 partition');
select is((select array[lo::timestamptz, hi::timestamptz]
             from pgpm._next_archive_chunk('public.u7r', :'mono_r')),
          array[date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) + interval '1 month'],
          'the chunk is exactly the monolith''s own [lo, hi)');

select lives_ok(format('select pgpm.regrain(%L, %L, %L)', 'public.u7r', :'mono_r', '1 month'),
                'regrain of a uuidv7 monolith completes');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.u7r'::regclass and attached
              and hi::timestamptz <= date_trunc('month', now()) + interval '1 month'),
          array[date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) - interval '1 month',
                date_trunc('month', now())],
          'the monolith is replaced by exactly its three monthly children');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.u7r),
          :'rows_r_before', 'every row survives the regrain: none lost, none duplicated');
select is((select coalesce(sum(rows), 0)::bigint from pgpm.log
            where parent_table = 'public.u7r'::regclass and action = 'regrain_copy'),
          :'n_r_hist'::bigint, 'the copy moved exactly the monolith''s rows');
select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.u7r'::regclass and action = 'regrain_copy'),
              '>', 3::bigint,
              'LIVENESS: more copy batches than months, so at least one batch resumed from the fine child''s newest id');

-- ============================================== (B) auto-regrain through maintain ticks
-- Daily rows, default batch, so each month copies in one tick and the whole regrain takes a few ticks.
-- Retention is configured here, at conversion, because set_retain() refuses a value whose next tick
-- would drop a partition, and part (C) needs exactly that state once the regrain has produced the aged
-- month. The archive strategy and budget are configured before the regrain for the same reason: with a
-- strategy present regrain_step copies the aged month instead of leaving it to be discarded at the swap.
create table public.u7a (id uuid primary key, payload text);
insert into public.u7a (id, payload)
select pgpm._ts_to_uuid(ts), 'a' || row_number() over (order by ts)
  from generate_series(date_trunc('month', now()) - interval '2 months',
                       now() - interval '1 minute', interval '1 day') ts;
call pgpm.transmute('public.u7a', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_retain => interval '1 month');
select pgpm.obtain('public.u7a');
insert into public.u7a (id, payload)
  values (pgpm._ts_to_uuid(date_trunc('month', now()) + interval '3 months 1 day'), 'frontier');
-- A 400-byte budget against ~50-byte rows forces the aged month into several chunks in part (C), which
-- is the only way the chunk boundary's tie extension (the min() site) is reached at all.
update pgpm.config set archive_byte_budget = 400 where parent_table = 'public.u7a'::regclass;
select pgpm.set_archive_fn('public.u7a', 'pgpm._archive_noop(regclass,name,text,text)');
select pgpm.set_regrain('public.u7a', '1 month');

select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_a_before from public.u7a \gset
select count(*) as n_a_hist from public.u7a
 where pgpm._uuid_to_ts(id) < date_trunc('month', now()) + interval '1 month' \gset

select is((select regrain_to from pgpm.config where parent_table = 'public.u7a'::regclass), '1 month',
          'LIVENESS: auto-regrain is armed');

-- v_status receives maintain()'s INOUT (PL/pgSQL needs a writable argument for it). Bounded: stop once no
-- coarse child remains, or after 12 ticks, whichever first.
do $$ declare i int := 0; v_status text; begin
  while i < 12 and exists (select 1 from pgpm.part
                            where parent_table = 'public.u7a'::regclass and attached
                              and hi::timestamptz > lo::timestamptz + interval '1 month') loop
    call pgpm.maintain('public.u7a', v_status);
    i := i + 1;
  end loop;
end $$;

select is((select array_agg(method) from pgpm.log
            where parent_table = 'public.u7a'::regclass and action = 'skip_regrain'),
          null, 'no maintenance tick deferred the regrain with an error');
select is((select array_agg(lo::timestamptz order by lo::timestamptz) from pgpm.part
            where parent_table = 'public.u7a'::regclass and attached
              and hi::timestamptz <= date_trunc('month', now()) + interval '1 month'),
          array[date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) - interval '1 month',
                date_trunc('month', now())],
          'LIVENESS: the ticks did the regrain: the monolith is now exactly its three monthly children');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.u7a),
          :'rows_a_before', 'every row survives the auto-regrain');
select is((select coalesce(sum(rows), 0)::bigint from pgpm.log
            where parent_table = 'public.u7a'::regclass and action = 'regrain_copy'),
          :'n_a_hist'::bigint, 'the ticks copied exactly the monolith''s rows');

-- ============================================== (C) archive chunking and retirement of the aged month
-- With retain = 1 month the horizon is the start of last month, so exactly the oldest monthly child
-- produced by (B) is aged: the ticks below must write-block it, archive it chunk by chunk and drop it.
select child_name as aged_a from pgpm.part
 where parent_table = 'public.u7a'::regclass and attached
   and hi::timestamptz = date_trunc('month', now()) - interval '1 month' \gset
select md5(string_agg(id::text || ':' || payload, ',' order by id)) as rows_a_kept from public.u7a
 where pgpm._uuid_to_ts(id) >= date_trunc('month', now()) - interval '1 month' \gset
select count(*) as n_a_aged from public.u7a
 where pgpm._uuid_to_ts(id) < date_trunc('month', now()) - interval '1 month' \gset

select is((select pgpm._retain_boundary(c)::timestamptz from pgpm.config c where c.parent_table = 'public.u7a'::regclass),
          date_trunc('month', now()) - interval '1 month',
          'LIVENESS: the retention horizon is the start of last month, so exactly the oldest month is aged');
select isnt((select archive_fn from pgpm.config where parent_table = 'public.u7a'::regclass), null::regprocedure,
            'LIVENESS: an archive strategy is configured, so retirement must go through the chunker');
select cmp_ok(:'n_a_aged'::bigint, '>', 8::bigint,
              'LIVENESS: the aged month holds more rows than one 400-byte chunk carries');

-- Bounded the same way: stop once no attached partition ends at the horizon (the aged month is gone),
-- or after 12 ticks.
do $$ declare i int := 0; v_status text; begin
  while i < 12 and exists (select 1 from pgpm.part
                            where parent_table = 'public.u7a'::regclass and attached
                              and hi::timestamptz = date_trunc('month', now()) - interval '1 month') loop
    call pgpm.maintain('public.u7a', v_status);
    i := i + 1;
  end loop;
end $$;

select is((select array_agg(method) from pgpm.log
            where parent_table = 'public.u7a'::regclass and action = 'skip_archive'),
          null, 'no archive tick was deferred with an error');
select cmp_ok((select count(*) from pgpm.archive_ledger where parent_table = 'public.u7a'::regclass),
              '>', 1::bigint,
              'LIVENESS: the aged month was archived in several budget-sized chunks, so the boundary and its tie extension both ran');
select is((select array[min(lo::timestamptz), max(hi::timestamptz)] from pgpm.archive_ledger
            where parent_table = 'public.u7a'::regclass),
          array[date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) - interval '1 month'],
          'the ledger covers exactly the aged month');
select is((select sum(rows_archived)::bigint from pgpm.archive_ledger where parent_table = 'public.u7a'::regclass),
          :'n_a_aged'::bigint, 'the strategy was handed every row of the aged month');
select is((select array_agg(array[lo::timestamptz, hi::timestamptz] order by lo::timestamptz) from pgpm.log
            where parent_table = 'public.u7a'::regclass and action = 'retain_drop'),
          array[array[date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) - interval '1 month']],
          'exactly one partition was retired, and it is the aged month');
select is(to_regclass(format('public.%I', :'aged_a')), null::regclass, 'the aged month''s relation is gone');
select is((select md5(string_agg(id::text || ':' || payload, ',' order by id)) from public.u7a),
          :'rows_a_kept', 'exactly the rows from last month onward remain');

select * from finish();
