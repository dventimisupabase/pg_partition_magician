-- Verifies adopt() registered the table and premade partitions ahead of the
-- write frontier, while leaving the active (current) interval in the DEFAULT.
create extension if not exists pgtap;

begin;
select plan(5);

select is(
  (select control_kind from pgpm.config where parent_table = 'public.messages'::regclass),
  'time',
  'config: control_kind time registered'
);

select is(
  (select premake from pgpm.config where parent_table = 'public.messages'::regclass),
  4,
  'config: premake = 4'
);

select cmp_ok(
  (select count(*) from pgpm.part
    where parent_table = 'public.messages'::regclass
      and lo::timestamptz > date_trunc('month', now()))::int,
  '>=', 4,
  'at least 4 future partitions are premade ahead of the frontier'
);

select ok(
  to_regclass('public.messages_p' || to_char(date_trunc('month', now()), 'YYYY_MM')) is null,
  'current month is NOT premade while its data is still in the DEFAULT'
);

-- premake is idempotent: everything ahead already exists, current still skipped
select is(
  pgpm.premake('public.messages'),
  0,
  'premake is idempotent (creates nothing on a second call)'
);

select * from finish();
rollback;
