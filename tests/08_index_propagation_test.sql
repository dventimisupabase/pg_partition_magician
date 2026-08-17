-- Verifies transmute() carried the old table's secondary index onto the parent as a
-- partitioned index (no duplicate/rebuild on the default), and that it propagates
-- to premade and drained partitions.
create extension if not exists pgtap;

select plan(4);

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

-- 5. the secondary index propagated to EVERY managed partition -- the monolith (holding all the closed
--    history) and the forward cells -- not just the default
select is(
  (select count(*) from pgpm.part p
     where p.parent_table = 'public.messages'::regclass and p.attached
       and not exists (
         select 1 from pg_index i
          where i.indrelid = ('public.' || p.child_name)::regclass
            and pg_get_indexdef(i.indexrelid) ilike '%tenant_id%created_at%'))::int,
  0,
  'every managed partition (monolith + forward cells) carries the secondary index'
);

select * from finish();
