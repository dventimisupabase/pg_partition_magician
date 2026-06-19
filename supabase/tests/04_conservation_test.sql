-- Verifies the migration neither loses nor duplicates any row.
create extension if not exists pgtap;

begin;
select plan(2);

create temporary table _before on commit drop as
select tenant_id, count(*) as n from public.messages group by tenant_id;

select pgpm.drain_all('public.messages', p_include_open => true);

select is(
  (select count(*) from public.messages)::bigint,
  (select coalesce(sum(n), 0) from _before)::bigint,
  'total row count is conserved across the migration'
);

select ok(
  not exists (
    select 1
      from _before b
      full join (
        select tenant_id, count(*) as n from public.messages group by tenant_id
      ) a on a.tenant_id = b.tenant_id
     where coalesce(b.n, 0) <> coalesce(a.n, 0)
  ),
  'per-tenant row counts are conserved (no loss, no duplication)'
);

select * from finish();
rollback;
