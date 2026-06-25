-- Step 1 of the bounded-child redesign (REDESIGN.md sections 6, 7): _part_name encodes a coarse
-- range as _p<lo>_to_<hi> (fine, one-step ranges keep the existing _p<lo>), and obtain skips a
-- candidate range that overlaps an existing attached partition (the coarse monolith) instead of
-- erroring on an overlapping CREATE.
create extension if not exists pgtap;
begin;
set time zone 'UTC';
select plan(8);

-- _part_name: a one-step range is FINE -> existing name, unchanged.
select is(
  pgpm._part_name('events', 'time', '1 mon', '2015-03-01 00:00:00+00', '2015-04-01 00:00:00+00')::text,
  'events_p2015_03',
  'time: one-step range -> fine name _p<lo> (unchanged)');

-- _part_name: a multi-step range is COARSE -> _p<lo>_to_<hi>.
select is(
  pgpm._part_name('events', 'time', '1 mon', '2015-03-01 00:00:00+00', '2026-07-01 00:00:00+00')::text,
  'events_p2015_03_to_2026_07',
  'time: multi-step range -> coarse name _p<lo>_to_<hi>');

-- _part_name: omitting hi keeps the legacy fine behavior (back-compat for existing callers).
select is(
  pgpm._part_name('events', 'time', '1 mon', '2015-03-01 00:00:00+00')::text,
  'events_p2015_03',
  'time: omitted hi -> fine name (back-compat)');

-- id grid: fine and coarse.
select is(
  pgpm._part_name('m', 'id', '1000', '0', '1000')::text,
  'm_p' || lpad('0', 19, '0'),
  'id: one-step range -> fine name');
select is(
  pgpm._part_name('m', 'id', '1000', '0', '5000')::text,
  'm_p' || lpad('0', 19, '0') || '_to_' || lpad('5000', 19, '0'),
  'id: multi-step range -> coarse name');

-- obtain overlap: a parent with a COARSE child covering [0, 5000), frontier (max id) at 4999.
-- The active grid cell [4000, 5000) sits inside the coarse child, so obtain must SKIP it (today it
-- would error on an overlapping CREATE) and start creating forward at the coarse hi (5000).
create table public.ovl (id bigint not null, payload text, primary key (id)) partition by range (id);
create table public.ovl_p0_to_5000 partition of public.ovl for values from (0) to (5000);
create table public.ovl_default partition of public.ovl default;
insert into public.ovl (id) values (100), (4999);   -- both route into the coarse child; DEFAULT stays empty
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor,
                         obtain, default_table, paused)
  values ('public.ovl'::regclass, 'id', 'id', '1000', '0', 4, 'ovl_default', false);
insert into pgpm.part (parent_table, child_name, lo, hi, attached)
  values ('public.ovl'::regclass, 'ovl_p0_to_5000', '0', '5000', true);

select lives_ok(
  $$ select pgpm.obtain('public.ovl') $$,
  'obtain does not error even though the coarse child covers the active interval');

select ok(
  to_regclass('public.ovl_p' || lpad('5000', 19, '0')) is not null,
  'obtain created the forward partition at the coarse hi (5000)');

select ok(
  to_regclass('public.ovl_p' || lpad('4000', 19, '0')) is null,
  'obtain did NOT create a partition overlapping the coarse child (4000)');

select * from finish();
rollback;
