-- transmute must carry the table's owner, grants, RLS, policies, comments and triggers onto the new
-- parent (issue #277).
--
-- CREATE TABLE ... LIKE carries columns, defaults, constraints, storage and generated-ness, and nothing
-- else. Everything here was left on the original, which becomes a child, while the application talks to
-- the parent.
--
-- EVERY ASSERTION BELOW IS BEHAVIOURAL, and that is the whole point. "The policy still exists somewhere"
-- passes against the broken code, because the monolith keeps its copy; what matters is what a role can
-- SEE when it queries the parent. Likewise a trigger is asserted by whether it FIRES for a row routed to
-- a partition minted after the conversion, not by whether pg_trigger has a row.
create extension if not exists pgtap;
select plan(15);

-- Roles are cluster-wide while the test database is per-file, so these are created only if absent and
-- never dropped. DROP ROLE would fail whenever any other database still holds an object they own, which
-- would kill this file before a single assertion ran -- a spurious failure that says nothing about the
-- code under test. Leaving them behind is harmless.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't72_owner')  then create role t72_owner;  end if;
  if not exists (select 1 from pg_roles where rolname = 't72_reader') then create role t72_reader; end if;
  if not exists (select 1 from pg_roles where rolname = 't72_writer') then create role t72_writer; end if;
end $$;

create table public.ev72 (id bigint primary key, tenant int not null, body text);
insert into public.ev72 select g, (g % 5) + 1, 'x' from generate_series(1, 2000) g;

comment on table public.ev72 is 'the events table';
comment on column public.ev72.tenant is 'tenant discriminator';

alter table public.ev72 owner to t72_owner;
grant select on public.ev72 to t72_reader;
grant insert, update on public.ev72 to t72_writer;
grant select (id, tenant) on public.ev72 to t72_writer;   -- column-level, which relacl alone does not carry

alter table public.ev72 enable row level security;
alter table public.ev72 force row level security;
create policy tenant_iso on public.ev72 for select to t72_reader using (tenant = 1);

create table public.ev72_fired (id bigint, at text);
create function public.ev72_trg() returns trigger language plpgsql as $$
begin insert into public.ev72_fired values (new.id, 'fired'); return new; end $$;
create trigger ev72_before before insert on public.ev72
  for each row execute function public.ev72_trg();

call pgpm.transmute('public.ev72', 'id', 3000, p_paused => false);

-- ============================ the security assertion ============================
-- The one that catches the real failure. Under the bug the policy is left on the monolith, the parent has
-- none, and a reader whose grants have been "repaired" sees EVERY row instead of its own tenant's.
-- Wrapped so a permission error becomes a FAILED ASSERTION rather than an aborted script. Under the bug
-- the reader has no grant at all, and a bare select would kill the file at this line, leaving the
-- remaining thirteen assertions unreported and the session still SET ROLE.
create function public.ev72_reader_count() returns int language plpgsql as $$
begin return (select count(*)::int from public.ev72);
exception when others then return -1;
end $$;

set role t72_reader;
select is(public.ev72_reader_count(), 400,
  'a non-owner sees ONLY the rows its policy allows, queried through the parent');
reset role;

-- ============================ owner, grants, RLS, comments ============================
select is((select pg_get_userbyid(relowner) from pg_class where oid = 'public.ev72'::regclass),
  't72_owner', 'the parent keeps the original owner');

select ok(has_table_privilege('t72_reader', 'public.ev72', 'select'),
  'table grants are replayed onto the parent');

select ok(has_table_privilege('t72_writer', 'public.ev72', 'insert')
      and has_table_privilege('t72_writer', 'public.ev72', 'update'),
  'including grants held by a second role');

select ok(has_column_privilege('t72_writer', 'public.ev72', 'tenant', 'select'),
  'and COLUMN-level grants, which relacl alone does not carry');

select ok((select relrowsecurity from pg_class where oid = 'public.ev72'::regclass),
  'row level security is enabled on the parent');

select ok((select relforcerowsecurity from pg_class where oid = 'public.ev72'::regclass),
  'and FORCE row level security, without which the owner would bypass the policy');

select is((select obj_description('public.ev72'::regclass, 'pg_class')), 'the events table',
  'the table comment survives');

select is((select col_description('public.ev72'::regclass,
             (select attnum from pg_attribute
               where attrelid = 'public.ev72'::regclass and attname = 'tenant'))),
  'tenant discriminator', 'and the column comment');

-- ============================ triggers ============================
-- Routed to the MONOLITH, which had the original trigger. If the recreated parent trigger also clones
-- onto the monolith without its original being dropped first, this row fires twice.
insert into public.ev72 values (2500, 1, 'monolith-bound');
select is((select count(*)::int from public.ev72_fired where id = 2500), 1,
  'a row routed to the monolith fires the trigger exactly ONCE, not twice');

-- Routed to a partition minted AFTER the conversion. This is the assertion that fails under the bug:
-- the trigger lives on the monolith, so anything routed elsewhere fires nothing.
select pgpm.obtain('public.ev72');
insert into public.ev72 values (3500, 1, 'forward-bound');
select is((select count(*)::int from public.ev72_fired where id = 3500), 1,
  'and so does a row routed to a partition minted AFTER the conversion');

-- ============================ minted partitions are owned by the table owner ============================
select is((select count(*)::int from pg_class c
            join pg_inherits i on i.inhrelid = c.oid
           where i.inhparent = 'public.ev72'::regclass
             and pg_get_userbyid(c.relowner) <> 't72_owner'),
  0, 'every partition, including ones minted by obtain, is owned by the table owner');

-- ============================ untransmute round-trips ============================
-- Its own table: untransmute is deliberately a one-way door once the frontier crosses B, and ev72 above
-- has already been obtained and written past it, so it cannot be reversed by design.
--
-- Asserted by whether the trigger FIRES, not by whether pg_trigger has a row. transmute drops the
-- monolith's own trigger in favour of the parent's clone, and DETACH strips clones, so a reversal that
-- forgets this hands back a table that looks intact and silently runs no triggers.
create table public.ev72u (id bigint primary key, body text);
insert into public.ev72u select g, 'x' from generate_series(1, 500) g;
create trigger ev72u_before before insert on public.ev72u
  for each row execute function public.ev72_trg();
call pgpm.transmute('public.ev72u', 'id', 3000, p_paused => false);
select pgpm.untransmute('public.ev72u');

insert into public.ev72u values (9001, 'after the round trip');
select is((select count(*)::int from public.ev72_fired where id = 9001), 1,
  'a trigger still FIRES on the table untransmute hands back, not stripped by the DETACH');

-- ============================ a shape that cannot be carried is REFUSED ============================
-- A partitioned table cannot host a row trigger with a transition table. Converting and dropping it
-- silently would be the same class of defect this issue is about, so it refuses instead.
create table public.ev72t (id bigint primary key, body text);
insert into public.ev72t select g, 'x' from generate_series(1, 100) g;
create function public.ev72t_trg() returns trigger language plpgsql as $$ begin return null; end $$;
create trigger ev72t_after after insert on public.ev72t
  referencing new table as newrows for each row execute function public.ev72t_trg();

select throws_ok($$ call pgpm.transmute('public.ev72t', 'id', 1000) $$, NULL,
  'a row trigger with a transition table is refused rather than silently dropped');

select is((select relkind::text from pg_class where oid = 'public.ev72t'::regclass), 'r',
  'and the refusal mutates nothing: the table is still unpartitioned');

select * from finish();
