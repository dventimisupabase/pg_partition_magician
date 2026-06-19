-- Verifies uuidv7 (time-grid, uuid-encoded boundaries) partitioning on
-- events_uuid: codec roundtrip, structure, premake, full drain, conservation.
create extension if not exists pgtap;

begin;
select plan(7);

-- the uuid<->ts codec roundtrips at ms resolution
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

-- premade future partitions (time grid: native bounds are timestamps)
select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_uuid'::regclass
      and lo::timestamptz > date_trunc('month', now()))::int,
  '>=', 2, 'at least 2 uuid partitions premade ahead of the frontier'
);

-- full drain
select pgpm.drain_all('public.events_uuid', p_include_open => true);

select is(
  (select count(*) from public.events_uuid_default)::int,
  0, 'DEFAULT fully drained for the uuid table'
);

select is(
  (select count(*) from public.events_uuid)::bigint,
  45000::bigint, 'row count conserved across the uuid migration'
);

select * from finish();
rollback;
