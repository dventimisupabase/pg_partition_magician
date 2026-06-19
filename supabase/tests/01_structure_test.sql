-- Verifies the conversion produced the intended partitioned structure.
create extension if not exists pgtap;

begin;
select plan(5);

select is(
  (select relkind::text from pg_class
    where relname = 'messages' and relnamespace = 'public'::regnamespace),
  'p',
  'public.messages is a partitioned table'
);

select ok(
  (select relispartition from pg_class
    where relname = 'messages_default' and relnamespace = 'public'::regnamespace),
  'messages_default is a partition'
);

select is(
  (select partdefid from pg_partitioned_table where partrelid = 'public.messages'::regclass),
  'public.messages_default'::regclass::oid,
  'messages_default is the DEFAULT partition'
);

select is(
  pg_get_partkeydef('public.messages'::regclass),
  'RANGE (created_at)',
  'messages is RANGE-partitioned on created_at'
);

select is(
  (select array_agg(a.attname order by k.ord)
     from pg_constraint c
     cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
     join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
    where c.conrelid = 'public.messages'::regclass and c.contype = 'p'),
  array['created_at','id']::name[],
  'primary key is (created_at, id) -- includes the partition key'
);

select * from finish();
rollback;
