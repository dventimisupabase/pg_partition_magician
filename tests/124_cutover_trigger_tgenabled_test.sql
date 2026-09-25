-- Issue #499: transmute's cutover and untransmute's reversal both replay a table's row triggers from
-- pg_get_triggerdef, and pg_get_triggerdef carries no pg_trigger.tgenabled. Until this fix every replayed
-- trigger therefore came back ENABLE (tgenabled 'O'), whatever it had been: a trigger the operator had
-- DISABLED fired again on the very next write and silently rewrote what was stored, an ENABLE ALWAYS
-- trigger stopped firing under session_replication_role = replica (a logical-replication apply worker, a
-- loader silencing triggers) and an ENABLE REPLICA one started firing for ordinary sessions. Nothing was
-- refused or logged, and reference.md promised the parent "takes over" the table's row triggers. Both
-- sites now capture tgname and tgenabled alongside each definition and re-apply the state after the
-- verbatim replay, at the parent (which recurses to every partition clone) and at the restored table.
--
-- Four triggers, one per state, each adding a DIFFERENT power of ten to n, so the value a row ends up with
-- says exactly which triggers fired and no two mistakes can cancel: a row written by an ordinary session
-- must carry 1001 (ALWAYS + ORIGIN), one applied under session_replication_role = replica must carry 11
-- (ALWAYS + REPLICA), and the DISABLED trigger's 100 must appear nowhere. Under the defect the same two
-- writes produce 1111 and 0. Every post-conversion assertion is paired with a pre-conversion witness that
-- the state it checks was really there to carry, and identity is asserted by WHICH ids carry which value.
create extension if not exists pgtap;

select plan(16);

create table public.ev499 (id bigint, t timestamptz not null default now(), n int default 0, primary key (id, t));
create function public.ev499_add1()    returns trigger language plpgsql as $$ begin new.n := new.n + 1;    return new; end $$;
create function public.ev499_add100()  returns trigger language plpgsql as $$ begin new.n := new.n + 100;  return new; end $$;
create function public.ev499_add10()   returns trigger language plpgsql as $$ begin new.n := new.n + 10;   return new; end $$;
create function public.ev499_add1000() returns trigger language plpgsql as $$ begin new.n := new.n + 1000; return new; end $$;

create trigger ev499_a_always   before insert on public.ev499 for each row execute function public.ev499_add1();
alter table public.ev499 enable always trigger ev499_a_always;
create trigger ev499_b_disabled before insert on public.ev499 for each row execute function public.ev499_add100();
alter table public.ev499 disable trigger ev499_b_disabled;
create trigger ev499_c_replica  before insert on public.ev499 for each row execute function public.ev499_add10();
alter table public.ev499 enable replica trigger ev499_c_replica;
create trigger ev499_d_origin   before insert on public.ev499 for each row execute function public.ev499_add1000();

-- ============================================== before: the four states, and what they do
select is(
  (select array_agg(tgname || ':' || tgenabled::text order by tgname)
     from pg_trigger where tgrelid = 'public.ev499'::regclass and not tgisinternal),
  array['ev499_a_always:A', 'ev499_b_disabled:D', 'ev499_c_replica:R', 'ev499_d_origin:O'],
  'LIVENESS: the plain table carries one trigger in each of the four enabled states');

insert into public.ev499 (id) values (1);
select is((select n from public.ev499 where id = 1), 1001,
  'LIVENESS: before conversion an ordinary write fires ALWAYS and ORIGIN only (1001), not the DISABLED or REPLICA trigger');

set session_replication_role = replica;
insert into public.ev499 (id) values (2);
reset session_replication_role;
select is((select n from public.ev499 where id = 2), 11,
  'LIVENESS: before conversion a replica-role write fires ALWAYS and REPLICA only (11), not ORIGIN');

-- ============================================== transmute: the states survive the cutover
call pgpm.transmute('public.ev499', 't', interval '1 month', p_obtain => 1);

select is(
  (select relkind::text from pg_class where oid = 'public.ev499'::regclass),
  'p', 'LIVENESS: the table really was converted, not refused');

select is(
  (select array_agg(tgname || ':' || tgenabled::text order by tgname)
     from pg_trigger where tgrelid = 'public.ev499'::regclass and not tgisinternal),
  array['ev499_a_always:A', 'ev499_b_disabled:D', 'ev499_c_replica:R', 'ev499_d_origin:O'],
  'the new parent carries every trigger in the state the original table had, not all ENABLE');

-- A row written through the parent fires the CLONE on the partition it lands in, so the parent's
-- catalog row alone proves nothing: every clone must carry the same state. distinct over every
-- partition collapses to exactly four entries only if no clone disagrees with its parent.
select is(
  (select array_agg(distinct s.state order by s.state)
     from (select t.tgname || ':' || t.tgenabled::text as state
             from pg_trigger t join pg_inherits i on i.inhrelid = t.tgrelid
            where i.inhparent = 'public.ev499'::regclass and not t.tgisinternal) s),
  array['ev499_a_always:A', 'ev499_b_disabled:D', 'ev499_c_replica:R', 'ev499_d_origin:O'],
  'every partition clone carries its parent trigger''s state');
select is(
  (select array_agg(t.tgname::text order by t.tgname) from pg_trigger t
    where not t.tgisinternal
      and t.tgrelid = (select format('%I.%I', 'public', child_name)::regclass from pgpm.part
                        where parent_table = 'public.ev499'::regclass order by lo::timestamptz limit 1)),
  array['ev499_a_always', 'ev499_b_disabled', 'ev499_c_replica', 'ev499_d_origin'],
  'LIVENESS: the monolith, where the writes below land, carries all four clones');

insert into public.ev499 (id) values (3);
select is((select n from public.ev499 where id = 3), 1001,
  'after conversion an ordinary write still fires ALWAYS and ORIGIN only: the DISABLED trigger stays silent, the REPLICA one too');

set session_replication_role = replica;
insert into public.ev499 (id) values (4);
reset session_replication_role;
select is((select n from public.ev499 where id = 4), 11,
  'after conversion a replica-role write still fires ALWAYS and REPLICA: neither has fallen back to ORIGIN');

-- ============================================== untransmute: the states survive the reversal too
-- Every row so far is in the monolith (all at now(), below the bound), so the door is open.
select pgpm.untransmute('public.ev499');

select is(
  (select relkind::text from pg_class where oid = 'public.ev499'::regclass),
  'r', 'LIVENESS: the reversal really happened, the table is plain again');

select is(
  (select array_agg(tgname || ':' || tgenabled::text order by tgname)
     from pg_trigger where tgrelid = 'public.ev499'::regclass and not tgisinternal),
  array['ev499_a_always:A', 'ev499_b_disabled:D', 'ev499_c_replica:R', 'ev499_d_origin:O'],
  'the restored table carries every trigger in the state the parent had, not all ENABLE');

insert into public.ev499 (id) values (5);
select is((select n from public.ev499 where id = 5), 1001,
  'after the reversal an ordinary write fires ALWAYS and ORIGIN only');

set session_replication_role = replica;
insert into public.ev499 (id) values (6);
reset session_replication_role;
select is((select n from public.ev499 where id = 6), 11,
  'after the reversal a replica-role write fires ALWAYS and REPLICA only');

-- ============================================== identity: which rows carry which value
select is((select array_agg(id order by id) from public.ev499 where n = 1001), array[1, 3, 5]::bigint[],
  'exactly the three ordinary-session rows carry 1001, one from each phase');
select is((select array_agg(id order by id) from public.ev499 where n = 11), array[2, 4, 6]::bigint[],
  'exactly the three replica-role rows carry 11, one from each phase');
select is((select array_agg(id order by id) from public.ev499 where n not in (1001, 11)), null::bigint[],
  'no row carries any other value: the DISABLED trigger''s 100 appears nowhere');

select * from finish();
