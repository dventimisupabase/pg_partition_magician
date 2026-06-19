-- Verifies that new writes route to proper partitions, not the DEFAULT.
create extension if not exists pgtap;

begin;
select plan(2);

-- A future-dated insert falls in a pre-created (empty) monthly partition.
insert into public.messages (tenant_id, created_at, body)
values (
  '00000000-0000-0000-0000-0000000000a1',
  date_trunc('month', now()) + interval '1 month' + interval '5 days',
  'routing-probe-future'
);

select isnt(
  (select tableoid::regclass::text from public.messages where body = 'routing-probe-future'),
  'messages_default',
  'future-dated insert does NOT land in the DEFAULT partition'
);

select is(
  (select tableoid from public.messages where body = 'routing-probe-future'),
  to_regclass('public.messages_' ||
    to_char((date_trunc('month', now()) + interval '1 month')::date, 'YYYY_MM'))::oid,
  'future-dated insert routes to its correct monthly partition'
);

select * from finish();
rollback;
