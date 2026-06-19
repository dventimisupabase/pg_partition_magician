-- Verifies integer/id-range partitioning (events_id): structure, premake ahead
-- of the id frontier, full drain, and row conservation. Robust to seed size.
create extension if not exists pgtap;

begin;
select plan(6);

select is(
  (select relkind::text from pg_class where relname = 'events_id' and relnamespace = 'public'::regnamespace),
  'p', 'events_id is a partitioned table'
);

select is(
  (select control_kind from pgpm.config where parent_table = 'public.events_id'::regclass),
  'id', 'config: control_kind = id'
);

select is(
  pg_get_partkeydef('public.events_id'::regclass),
  'RANGE (id)', 'events_id is RANGE-partitioned on id'
);

-- premade partitions sit ahead of the current id frontier
select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_id'::regclass
      and lo::numeric > (select max(id) from public.events_id))::int,
  '>=', 2, 'at least 2 id partitions premade ahead of the frontier'
);

create temporary table _before_id on commit drop as select count(*) as n from public.events_id;
select pgpm.drain_all('public.events_id', p_include_open => true);

select is(
  (select count(*) from public.events_id_default)::int,
  0, 'DEFAULT fully drained for the id table'
);

select is(
  (select count(*) from public.events_id)::bigint,
  (select n from _before_id)::bigint, 'row count conserved across the id migration'
);

select * from finish();
rollback;
