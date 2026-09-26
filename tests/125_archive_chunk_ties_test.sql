-- Issue #513: pgpm._next_archive_chunk ends a chunk at "the next distinct control value", and decodes
-- that value to the native grid. For text_time and uuidv7 the decode truncates to the encoding's unit
-- (a second for ObjectId and KSUID, a millisecond for uuidv7, ULID and cuid), so when one unit holds at
-- least a chunk's worth of rows (a bulk import minted within one second) the next distinct COLUMN value
-- decodes to the chunk's own lo: v_stop = v_lo, the picker returned no chunk, _archive_step `continue`d
-- without a log row, and every later tick resumed from the same lo and stopped there again. The partition
-- was never covered, so retire() never dropped it, and status() showed nothing. The fix extends the chunk
-- past the unit: to the first row minted after lo's unit, or to the child's hi when there is none, so a
-- run of ties on the native grid travels whole (over budget, as a run of ties on the column always did).
--
-- The fixture is the issue's own, at pgTAP size: ObjectId-shaped ids (8 hex digits of Unix seconds), 100
-- rows minted in the one second 2020-01-15 00:00:00, and a 2000-byte budget that holds about 35 of them.
-- One marker row before the burst and two after it in the same partition, so the chunk that crosses the
-- burst has a real next native value to end at (2020-01-20) and the chunk after it is the short read that
-- reaches the partition's hi; a fourth marker a month on; a live marker the year after, which retention
-- must not reach. The counts are asymmetric on purpose (1, 100, 3, and 2 survivors) so that no two chunk
-- errors can cancel in a total.
--
-- Getting a text_time partition in front of the archive step takes one device. Its frontier is
-- greatest(max(control), now()), so the monolith transmute builds always holds now(): it is never behind
-- the retention horizon (the issue's own repro founders on exactly this, its liveness witness failing on
-- every commit), and regrain_step refuses it as 'active'. A row two years out, in a partition
-- pgpm.extend_to built for it, pins the frontier there (tests/123 uses the same skewed-client device the
-- other way round); the monolith is then frozen and a hand-driven regrain, as in tests/74, splits it into
-- year children. The 2020 child is behind a horizon pinned by p_retain at 2021-06-15 (floor: 2021-01-01),
-- and the ordinary pipeline (write-block, archive, retire) takes it from there.
--
-- The same collapse happens at the millisecond for a uuidv7 column, and the fix covers it by the same
-- step (one unit on, then the first row past it). It is not exercised here because the picker's uuidv7
-- path cannot run at all on the commit this file was written against (max(uuid) does not exist, the
-- separate defect of issue #507); once that is fixed, a pick-record-pick on a uuidv7 monolith with 100
-- ids in one millisecond is the ten-line addition that closes the gap.
set timezone = 'UTC';
create extension if not exists pgtap;

select plan(13);

create schema pgpm_test124;

-- ObjectId shape: 8 hex digits of Unix seconds, then 16 hex digits (real ids carry machine, pid and
-- counter there; only the width and the ordering matter here).
create function pgpm_test124.oid_at(p_ts timestamptz, p_n bigint) returns text language sql immutable as
  $$ select lpad(to_hex(extract(epoch from p_ts)::bigint), 8, '0') || lpad(to_hex(p_n), 16, '0') $$;

create table public.oid124 (id text collate "C" primary key, v int not null);
insert into public.oid124 values (pgpm_test124.oid_at('2020-01-10 00:00:00+00', 1), -1);        -- before the burst
insert into public.oid124
  select pgpm_test124.oid_at('2020-01-15 00:00:00+00', g), g from generate_series(1, 100) g;     -- the burst: one second
insert into public.oid124 values (pgpm_test124.oid_at('2020-01-20 00:00:00+00', 1), -4);        -- after the burst,
insert into public.oid124 values (pgpm_test124.oid_at('2020-01-21 00:00:00+00', 1), -5);        -- same partition
insert into public.oid124 values (pgpm_test124.oid_at('2020-02-10 00:00:00+00', 1), -2);        -- a month on

-- retention pinned so the horizon is 2021-06-15 whenever this runs (floor on the year grid: 2021-01-01)
select (now() - timestamptz '2021-06-15 00:00:00+00') as ret \gset
call pgpm.transmute('public.oid124', 'id', interval '1 year', p_obtain => 1, p_retain => :'ret'::interval,
  p_paused => false, p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');

-- the strategy first: regrain materializes an aged sub-range only when archive_fn is set (otherwise it
-- is skipped as regrain_aged and there is nothing for the archive step to work on)
select pgpm.set_archive_fn('public.oid124', 'pgpm._archive_noop(regclass,name,text,text)');
update pgpm.config set archive_byte_budget = 2000 where parent_table = 'public.oid124'::regclass;

-- pin the frontier: 15 June, two years from this year, in a partition built for it
select (date_trunc('year', now()) + interval '2 years 5 months 14 days') as t_pin \gset
select pgpm.extend_to('public.oid124', pgpm_test124.oid_at(:'t_pin'::timestamptz, 1)) as extended \gset
insert into public.oid124 values (pgpm_test124.oid_at(:'t_pin'::timestamptz, 1), -9);
insert into public.oid124 values (pgpm_test124.oid_at('2021-03-10 00:00:00+00', 1), -3);       -- live: must survive

select is(pgpm._frontier_native('public.oid124')::timestamptz, :'t_pin'::timestamptz,
  'LIVENESS: the frontier is pinned two years out by the -9 row, so the monolith is frozen and can regrain');

-- split the monolith into year children, as tests/74 does
create table pgpm_test124.regrain as select null::text as last_status, 0 as ticks;
do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.oid124'::regclass
     and lo::timestamptz = '2020-01-01 00:00:00+00';
  loop
    v_status := pgpm.regrain_step('public.oid124', v_child, '1 year', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or v_status in ('active', 'nokey', 'nosubdiv') or i > 100;
  end loop;
  update pgpm_test124.regrain set last_status = v_status, ticks = i;
end $$;
select alike((select last_status from pgpm_test124.regrain), 'swapped:%',
  'LIVENESS: the regrain swapped the monolith for year children');

select child_name as y2020 from pgpm.part
 where parent_table = 'public.oid124'::regclass and lo::timestamptz = '2020-01-01 00:00:00+00' \gset
select is((select hi::timestamptz from pgpm.part where parent_table = 'public.oid124'::regclass and child_name = :'y2020'),
  timestamptz '2021-01-01 00:00:00+00',
  'LIVENESS: the 2020 child is [2020-01-01, 2021-01-01), at the horizon and so drop-eligible');

-- the conditions for the defect: one native second holding more rows than the budget admits
select is((select array_agg(distinct pgpm._text_time_to_ts(id, '', 8, 16, 's')) from public.oid124 where v > 0),
  array[timestamptz '2020-01-15 00:00:00+00'],
  'LIVENESS: every burst row decodes to the one native second 2020-01-15 00:00:00');
select is((select count(*)::int from public.oid124 where v > 0), 100,
  'LIVENESS: and there are 100 of them');
select cmp_ok((select floor(2000 / avg(pg_column_size(t.*)))::int from public.oid124 t where v > 0), '<', 100,
  'LIVENESS: a 2000-byte budget holds fewer than 100 of these rows, so the burst cannot fit one chunk');

-- ---------------------------------------------------------------------------------------------------
-- tick one: the child is write-blocked and the first chunk stops at the burst's second

call pgpm.maintain('public.oid124');

select ok(pgpm._is_write_blocked('public.oid124', :'y2020'),
  'LIVENESS: after one tick the 2020 child is write-blocked, so the archive step is working on it');
select is((select array_agg(format('[%s, %s) %s', to_char(lo::timestamptz, 'YYYY-MM-DD'),
                                   to_char(hi::timestamptz, 'YYYY-MM-DD'), rows_archived) order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 'public.oid124'::regclass and child_name = :'y2020'),
  array['[2020-01-01, 2020-01-15) 1'],
  'LIVENESS: the first chunk ends at the burst second and holds only the marker before it: the burst is what the next chunk must cross');

-- ---------------------------------------------------------------------------------------------------
-- the rest of the pipeline, up to a dozen ticks or until the child is retired

do $$ declare i int := 0; v_status text; begin
  while i < 12 and exists (select 1 from pgpm.part where parent_table = 'public.oid124'::regclass
                            and lo::timestamptz = '2020-01-01 00:00:00+00') loop
    call pgpm.maintain('public.oid124', v_status);
    i := i + 1;
  end loop;
end $$;

-- THE assertion: the burst travelled whole, in the chunk after the first, ended by the next native value
-- present in the child; the short read after it reached the child's hi. The defect left the ledger at the
-- first row of this array, tick after tick, with nothing logged.
select is((select array_agg(format('[%s, %s) %s', to_char(lo::timestamptz, 'YYYY-MM-DD'),
                                   to_char(hi::timestamptz, 'YYYY-MM-DD'), rows_archived) order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 'public.oid124'::regclass and child_name = :'y2020'),
  array['[2020-01-01, 2020-01-15) 1', '[2020-01-15, 2020-01-20) 100', '[2020-01-20, 2021-01-01) 3'],
  'the chunk after the first carries the whole burst and ends at 2020-01-20, the first row minted after its second; the next reaches hi');

select ok(exists (select 1 from pgpm.log where parent_table = 'public.oid124'::regclass and action = 'retain_drop'
                   and lo::timestamptz = '2020-01-01 00:00:00+00'),
  'once covered, retire dropped the 2020 child (retain_drop logged with its lo)');
select is(to_regclass(format('public.%I', :'y2020')), null::regclass,
  'and the 2020 relation is gone');
select is((select array_agg(v order by v) from public.oid124), array[-9, -3],
  'what remains is exactly the live marker and the frontier pin: the burst and the four aged markers went with the child');

-- The silence the issue names: nothing was deferred or refused on the way, on the defective code either.
-- Paired with the ledger assertions above, which show the steps that could have logged these did run.
select is((select array_agg(distinct action order by action) from pgpm.log
            where parent_table = 'public.oid124'::regclass
              and action in ('skip_archive', 'fail_archive_identity', 'fail_archive_contract',
                             'skip_retain', 'fail_retain_drop', 'fail_retain_identity', 'fail_retain_detach',
                             'fail_retain_crossing', 'skip_write_block', 'skip_regrain')),
  null,
  'no archive, retain or regrain step was deferred or refused along the way');

select * from finish();
