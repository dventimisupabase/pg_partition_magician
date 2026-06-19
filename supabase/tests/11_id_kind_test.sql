-- Verifies integer/id-range partitioning (events_id): structure, premake ahead
-- of the id frontier, full drain, and row conservation.
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

-- premade partitions ahead of the current max id (~45000)
select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.events_id'::regclass and lo::numeric > 45000)::int,
  '>=', 2, 'at least 2 id partitions premade ahead of the frontier'
);

-- drive the full drain (closed id-ranges + the active one)
select pgpm.drain_all('public.events_id', p_include_open => true);

select is(
  (select count(*) from public.events_id_default)::int,
  0, 'DEFAULT fully drained for the id table'
);

select is(
  (select count(*) from public.events_id)::bigint,
  45000::bigint, 'row count conserved across the id migration'
);

select * from finish();
rollback;
