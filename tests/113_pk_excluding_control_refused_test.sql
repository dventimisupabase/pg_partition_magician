-- A PRIMARY KEY that excludes the control column is refused even when a UNIQUE constraint includes it (#445).
--
-- The docs have always said this shape is refused, and it was, but only when the table had nothing else
-- to adopt. With a PK on (id) and a UNIQUE on (tenant, created_at), a transmute on created_at fell through
-- to the unique-constraint branch: the parent adopted the UNIQUE, the PK stayed on the monolith, and every
-- forward partition enforced only (tenant, created_at). Duplicate ids were accepted from then on, with no
-- error, notice or log row. A primary key cannot be carried onto a partitioned table unless it includes
-- the partition key, and pgpm never rewrites keys, so refusal is the only honest option, and it must not
-- depend on what other unique constraints happen to exist.
--
-- WHICH ASSERTION BELOW ACTUALLY DISCRIMINATES: the throws_like on the refusal message, and only that one.
-- throws_like is a FUNCTION, and a committing procedure cannot commit inside one, so against pre-fix code
-- the CALL proceeds past the key checks and dies at phase 1's COMMIT with 2D000 "invalid transaction
-- termination" (tests/83 explains the same trap). That message does not match the pattern, so the guard
-- fails; a NULL errcode or a bare P0001 would have accepted the wrong exception. The state checks after
-- it pass pre-fix too, for the wrong reason (the 2D000 rolls everything back), and characterise the
-- post-fix contract: the refusal happens before any COMMIT, so no claim row and no bound CHECK are left
-- behind. The positive controls show the remedy the message prescribes is accepted and that the widened
-- key really is enforced on a forward partition, which is the property the defect took away.
create extension if not exists pgtap;

select plan(11);

-- The issue's fixture: a PK that excludes the control column AND a UNIQUE constraint that includes it.
create table public.t1 (id bigint primary key, created_at timestamptz not null, tenant int not null,
                        constraint t1_tenant_created_uq unique (tenant, created_at));
insert into public.t1 (id, created_at, tenant)
  select g, now() - (g || ' hours')::interval, g % 3 from generate_series(1, 20) g;

-- Witnesses: both shapes are really present before the call. Without the UNIQUE the old code refused
-- already; without the PK the UNIQUE is the supported reuse (tests/49). Both must be there for this to
-- test anything.
select is(
  (select array_agg(a.attname::text order by k.ord)
     from pg_constraint con
     cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
     join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
    where con.conrelid = 'public.t1'::regclass and con.contype = 'p' and con.conname = 't1_pkey'),
  array['id'],
  'witness: t1_pkey is the primary key and its key is (id), which excludes created_at');
select is(
  (select array_agg(a.attname::text order by k.ord)
     from pg_constraint con
     cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
     join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
    where con.conrelid = 'public.t1'::regclass and con.contype = 'u' and con.conname = 't1_tenant_created_uq'),
  array['tenant', 'created_at'],
  'witness: a UNIQUE constraint whose key includes created_at is present (the shape that used to be adopted)');

-- The refusal names the primary key constraint and the control column.
select throws_like(
  $$ call pgpm.transmute('public.t1', 'created_at', interval '1 day', p_obtain => 5) $$,
  'pg_partition_magician: cannot partition %t1 on created_at%the primary key t1_pkey (id) does not include created_at%',
  'transmute refuses a PK that excludes the control column even though a UNIQUE constraint includes it, naming t1_pkey and created_at');

-- Up front: before anything is committed, so the operator is left exactly where they started.
select is((select relkind::text from pg_class where oid = 'public.t1'::regclass), 'r',
  'the table is still a plain table');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.t1'::regclass and conname = 'pgpm_monolith_bound'),
  'no pgpm_monolith_bound CHECK was left on the table');
select is((select count(*) from pgpm.transmute_inflight), 0::bigint,
  'no transmute_inflight claim row was left behind');

-- Positive control: the remedy the message prescribes. Widen the key to include the control column and
-- the same table transmutes; the primary key is carried onto the parent.
alter table public.t1 drop constraint t1_pkey, add primary key (id, created_at);
call pgpm.transmute('public.t1', 'created_at', interval '1 day', p_obtain => 5);
select pass('after widening the primary key to (id, created_at) the same table transmutes');
select is((select relkind::text from pg_class where oid = 'public.t1'::regclass), 'p',
  'the table is now partitioned');
select is(
  (select array_agg(a.attname::text order by k.ord)
     from pg_constraint con
     cross join lateral unnest(con.conkey) with ordinality as k(attnum, ord)
     join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k.attnum
    where con.conrelid = 'public.t1'::regclass and con.contype = 'p'),
  array['id', 'created_at'],
  'the parent carries the widened primary key (id, created_at)');

-- Positive control: the key is enforced on a FORWARD partition, the place the defect left keyless. A fresh
-- row lands there (witness: a different partition from the monolith row id 1 sits in), and the same
-- (id, created_at) again is refused by the PK. The tenant differs, so the UNIQUE (tenant, created_at)
-- cannot be the constraint that fires; only the primary key can.
create temporary table _ts as select date_trunc('day', now()) + interval '3 days 1 hour' as ts0;
insert into public.t1 (id, created_at, tenant) values (1000, (select ts0 from _ts), 7);
select isnt(
  (select tableoid::regclass::text from public.t1 where id = 1000),
  (select tableoid::regclass::text from public.t1 where id = 1),
  'witness: the fresh row landed in a forward partition, not in the monolith');
select throws_like(
  $$ insert into public.t1 (id, created_at, tenant) values (1000, (select ts0 from _ts), 8) $$,
  'duplicate key value violates unique constraint "t1_p%_pkey"',
  'a duplicate (id, created_at) in a forward partition is refused by that partition''s primary key');

select * from finish();
