-- Verifies retention drops partitions older than the policy and keeps the rest.
create extension if not exists pgtap;

begin;
select plan(3);

-- materialize all historical partitions first
select pgpm.drain_all('public.messages', p_include_open => true);

update pgpm.config set retention = '2 months' where parent_table = 'public.messages'::regclass;

select cmp_ok(
  pgpm.retention('public.messages'),
  '>', 0,
  'retention dropped at least one partition older than the policy'
);

select ok(
  to_regclass('public.messages_p' || to_char(date_trunc('month', now()) - interval '3 months', 'YYYY_MM')) is null,
  'a partition older than the 2-month policy was dropped'
);

select ok(
  to_regclass('public.messages_p' || to_char(date_trunc('month', now()) - interval '1 month', 'YYYY_MM')) is not null,
  'a within-policy partition survives'
);

select * from finish();
rollback;
