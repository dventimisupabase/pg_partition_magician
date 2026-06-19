-- Verifies adopt() carried the old table's secondary index onto the parent as a
-- partitioned index (no duplicate/rebuild on the default), and that it propagates
-- to premade and drained partitions.
create extension if not exists pgtap;

begin;
select plan(5);

-- helper predicate: does relation <rel> have an index on (tenant_id, created_at)?
-- (matched loosely on the index definition)

-- 1. parent has the tenant lookup index (partitioned)
select ok(
  exists (
    select 1 from pg_index i
     where i.indrelid = 'public.messages'::regclass
       and not i.indisprimary
       and pg_get_indexdef(i.indexrelid) ilike '%tenant_id%created_at%'
  ),
  'parent has the (tenant_id, created_at) secondary index'
);

-- 2. it is a PARTITIONED index (relkind I), i.e. propagates to partitions
select ok(
  exists (
    select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
     where i.indrelid = 'public.messages'::regclass
       and c.relkind = 'I'
       and pg_get_indexdef(i.indexrelid) ilike '%tenant_id%created_at%'
  ),
  'the secondary index on the parent is a partitioned index'
);

-- 3. the DEFAULT has exactly two indexes (PK unique + attached secondary) -- no
--    duplicate from a rebuild
select is(
  (select count(*) from pg_index where indrelid = 'public.messages_default'::regclass)::int,
  2,
  'DEFAULT has exactly 2 indexes (PK + attached secondary, no rebuilt duplicate)'
);

-- 4. a premade future partition inherited the secondary index
select ok(
  exists (
    select 1 from pg_index i
     where i.indrelid = ('public.messages_p' ||
            to_char(date_trunc('month', now()) + interval '1 month', 'YYYY_MM'))::regclass
       and pg_get_indexdef(i.indexrelid) ilike '%tenant_id%created_at%'
  ),
  'a premade partition inherited the secondary index'
);

-- 5. a drained (closed-month) partition also has it
select pgpm.drain_all('public.messages', p_include_open => true);
select ok(
  exists (
    select 1 from pg_index i
     where i.indrelid = ('public.messages_p' ||
            to_char(date_trunc('month', now()) - interval '1 month', 'YYYY_MM'))::regclass
       and pg_get_indexdef(i.indexrelid) ilike '%tenant_id%created_at%'
  ),
  'a drained partition has the secondary index'
);

select * from finish();
rollback;
