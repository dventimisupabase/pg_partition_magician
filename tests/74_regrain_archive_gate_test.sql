-- regrain must not destroy aged rows that the archive gate is protecting (issue #278).
--
-- retire refuses to drop a partition until archiving has fully covered it, which is the guarantee the
-- README states as "a partition only drops once it's fully archived, never before". regrain used to
-- discard aged sub-ranges with the source at the swap, never materializing them, so with archive_fn set
-- it destroyed exactly the rows that gate was holding back, unarchived.
--
-- The skip's own comment justified itself with "they would be dropped by retain() the instant they became
-- partitions". That stopped being true at #238, when retire gained the coverage gate.
--
-- The fix is to stop skipping when archive_fn is set: the aged sub-range becomes an ordinary fine child,
-- and the existing pipeline (write-block, then archive, then retire) takes it from there, already gated.
-- With no archive_fn the cheap skip is unchanged, because retire's gate is a no-op with nothing to cover.
create extension if not exists pgtap;
select plan(11);

-- ============================ archive_fn SET: aged rows must survive the regrain ============================
create table public.ag74 (id bigint primary key, payload text);
insert into public.ag74 select g, repeat('x',100) from generate_series(1, 2000) g;
call pgpm.transmute('public.ag74', 'id', 1000, p_retain => 97000::bigint, p_paused => false);
insert into public.ag74 values (100000, 'frontier');   -- pushes the horizon to 3000: the child is fully aged
-- A deliberately tiny byte budget, so coverage is INCOMPLETE when the regrain runs. That is the whole
-- point: with coverage already complete there would be nothing for the gate to protect.
update pgpm.config set archive_byte_budget = 2000,
       archive_fn = 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure
 where parent_table = 'public.ag74'::regclass;

-- Liveness witness for the setup, not a test of the fix: if retire were willing to drop this child, the
-- rows would not be under the gate's protection and everything below would prove nothing.
select is(pgpm.retain('public.ag74'), 0,
  'setup: retire refuses to drop the child because archive coverage is incomplete');
select ok(not (select pgpm._archive_fully_covered('public.ag74', child_name)
                 from pgpm.part where parent_table = 'public.ag74'::regclass),
  'setup: and the child is genuinely not fully covered');

do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.ag74'::regclass;
  loop
    v_status := pgpm.regrain_step('public.ag74', v_child, '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;

-- THE assertion. Behavioural: the rows are still readable through the parent. A structural check that a
-- child exists would not catch a regrain that materialized the wrong thing.
select is((select count(*)::int from public.ag74), 2001,
  'a regrain does NOT destroy aged rows while archive coverage is incomplete');

select is((select count(*)::int from pgpm.log
            where parent_table = 'public.ag74'::regclass and action = 'regrain_aged'),
  0, 'no sub-range was discarded as aged: with archive_fn set they are materialized instead');

select cmp_ok((select count(*) from pgpm.part
                where parent_table = 'public.ag74'::regclass and hi::bigint <= 3000), '>', 0::bigint,
  'the aged sub-ranges exist as real partitions, which is what puts them under the gate');

-- ============================ and the normal pipeline then archives and drops them ============================
-- The point is not that the rows survive forever, it is that they are archived BEFORE they are dropped.
update pgpm.config set archive_byte_budget = 8 * 1024 * 1024
 where parent_table = 'public.ag74'::regclass;
-- v_status only exists to receive maintain()'s INOUT: PL/pgSQL requires a writable argument for an output
-- parameter, so the parameter's default cannot be relied on from inside a block.
do $$ declare i int := 0; v_status text; begin
  while i < 40 and exists(select 1 from pgpm.part
                           where parent_table = 'public.ag74'::regclass and hi::bigint <= 3000) loop
    call pgpm.maintain('public.ag74', v_status);
    i := i + 1;
  end loop;
end $$;

select cmp_ok((select count(*) from pgpm.archive_ledger where parent_table = 'public.ag74'::regclass),
  '>', 0::bigint, 'maintenance archived the materialized aged children');

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.ag74'::regclass and action = 'retain_drop'),
  '>', 0::bigint, 'and only then did retire drop them, through the gated path');

select is((select count(*)::int from pgpm.part
            where parent_table = 'public.ag74'::regclass and hi::bigint <= 3000),
  0, 'so the aged rows are gone in the end, but archived first rather than discarded');

-- ============================ a PARTIALLY aged child keeps its aged remainder ============================
-- The insidious case from the issue: the live sub-ranges copy normally and the aged ones vanish, so the
-- loss is a subset of a child that otherwise looks correctly regrained. It is also the case that makes
-- "wait for coverage" unimplementable, since a straddling child is never write-blocked and so never archived.
create table public.pa74 (id bigint primary key, payload text);
insert into public.pa74 select g, repeat('x',100) from generate_series(1, 2000) g;
call pgpm.transmute('public.pa74', 'id', 1000, p_retain => 99000::bigint, p_paused => false);
insert into public.pa74 values (100000, 'frontier');   -- horizon 1000, child [0,3000): straddles it
update pgpm.config set archive_byte_budget = 2000,
       archive_fn = 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure
 where parent_table = 'public.pa74'::regclass;

do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.pa74'::regclass;
  loop
    v_status := pgpm.regrain_step('public.pa74', v_child, '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;

select is((select count(*)::int from public.pa74 where id < 1000), 999,
  'a PARTIALLY aged child keeps the rows below the horizon instead of silently dropping them');
select is((select count(*)::int from public.pa74), 2001,
  'and the rest of it regrains normally, so nothing is lost either side of the boundary');

-- ============================ no archive_fn: the cheap skip is unchanged ============================
-- Documented behaviour, not an oversight: with nothing to archive, retire's gate is a no-op, so
-- materializing aged rows only to drop them would be pure cost.
create table public.na74 (id bigint primary key, payload text);
insert into public.na74 select g, repeat('x',100) from generate_series(1, 2000) g;
call pgpm.transmute('public.na74', 'id', 1000, p_retain => 97000::bigint, p_paused => false);
insert into public.na74 values (100000, 'frontier');

do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.na74'::regclass;
  loop
    v_status := pgpm.regrain_step('public.na74', v_child, '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;

select cmp_ok((select count(*) from pgpm.log
                where parent_table = 'public.na74'::regclass and action = 'regrain_aged'),
  '>', 0::bigint, 'with no archive_fn the aged sub-ranges are still skipped, as documented');

select * from finish();
