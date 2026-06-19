-- Verifies uuidv7 (time-grid, uuid-encoded boundaries) partitioning on
-- events_uuid: codec roundtrip, structure, premake, full drain, conservation.
-- Robust to seed size.
create extension if not exists pgtap;

begin;
select plan(7);

select is(
  pgpm._uuid_to_ts(pgpm._ts_to_uuid('2026-07-15 12:00:00+00'::timestamptz)),
  '2026-07-15 12:00:00+00'::timestamptz,
  'uuid<->timestamp codec roundtrips at ms resolution'
);

select is(
  (select relkind::text from pg_class where relname = 'events_uuid' and relnamespace = 'public'::regnamespace),
  'p', 'events_uuid is a partitioned table'
);

select is(
  (select control_kind from pgpm.config where parent_table = 'public.events_uuid'::regclass),
  'uuidv7', 'config: control_kind = uuidv7'
);

select is(
  pg_get_partkeydef('public.events_uuid'::regclass),
  'RANGE (id)', 'events_uuid is RANGE-partitioned on the uuid id'
);

select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_uuid'::regclass
      and lo::timestamptz > date_trunc('month', now()))::int,
  '>=', 2, 'at least 2 uuid partitions premade ahead of the frontier'
);

create temporary table _before_uuid on commit drop as select count(*) as n from public.events_uuid;
select pgpm.drain_all('public.events_uuid', p_include_open => true);

select is(
  (select count(*) from public.events_uuid_default)::int,
  0, 'DEFAULT fully drained for the uuid table'
);

select is(
  (select count(*) from public.events_uuid)::bigint,
  (select n from _before_uuid)::bigint, 'row count conserved across the uuid migration'
);

select * from finish();
rollback;
