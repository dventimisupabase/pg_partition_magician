-- pgpm builds a complete forward grid and keeps no DEFAULT partition (issue #288).
--
-- The DEFAULT used to catch any row with no matching partition, and the DRAIN existed to evacuate it.
-- Both are gone. That removes pgpm's only RI window (suspend_incoming_fks existed solely because the
-- drain moved a row briefly outside the parent), the whole adaptive-feathering subsystem, and obtain's
-- exclusion-constraint dance, which only ever existed to prove the DEFAULT held no row in a new range.
--
-- The price is that a write with nowhere to go now FAILS instead of landing somewhere. That is deliberate,
-- and this file pins it as a contract rather than treating it as an accident: tests 6 to 8 assert the
-- errors. `obtain x partition_step` is now a hard ceiling on how far ahead you can write, and the floor
-- moves up behind retention.
create extension if not exists pgtap;
select plan(12);

create table public.nd (id bigint primary key, body text);
insert into public.nd select g, 'x' from generate_series(1, 2500) g;
call pgpm.transmute('public.nd', 'id', 1000, p_paused => false);

-- ============================ no DEFAULT, and a forward grid instead ============================
select is((select count(*)::int from pg_class c
            join pg_inherits i on i.inhrelid = c.oid
           where i.inhparent = 'public.nd'::regclass and c.relname like '%_default'),
  0, 'transmute creates NO default partition');

select ok((select count(*) from pg_inherits where inhparent = 'public.nd'::regclass) > 1,
  'and builds forward partitions in the cutover instead, so writes past the monolith have somewhere to go');

-- The monolith covers [0,3000). The forward grid must start exactly there, with no gap: a gap would be a
-- silent write failure waiting to happen.
select is((select min(lo::bigint)::int from pgpm.part
            where parent_table = 'public.nd'::regclass and lo::bigint >= 3000),
  3000, 'the forward grid starts flush against the monolith''s upper bound, leaving no gap');

select is((select count(*)::int from pgpm.part where parent_table = 'public.nd'::regclass) - 1,
  (select obtain from pgpm.config where parent_table = 'public.nd'::regclass),
  'and extends exactly config.obtain steps beyond it');

-- ============================ writes inside the grid land in real partitions ============================
insert into public.nd values (3500, 'just past the monolith');
select is((select count(*)::int from public.nd where id = 3500), 1,
  'a write past the monolith lands in a real partition, with no DEFAULT to catch it');

select isnt((select tableoid::regclass::text from public.nd where id = 3500),
  'public.nd', 'and it is genuinely in a child, not the parent');

-- ============================ and outside it, they FAIL, on purpose ============================
-- The accepted cost of removing the DEFAULT. Asserted so a future change cannot quietly reintroduce a
-- catch-all and call it a fix.
select throws_ok(
  format($$ insert into public.nd values (%s, 'beyond the lookahead') $$,
         (select max(hi::bigint) + 1 from pgpm.part where parent_table = 'public.nd'::regclass)),
  '23514', NULL,
  'a write BEYOND the lookahead is refused: obtain x step is now a hard write-ahead ceiling');

-- ============================ obtain keeps the grid ahead of the frontier ============================
select pgpm.obtain('public.nd');
select cmp_ok((select max(hi::bigint) from pgpm.part where parent_table = 'public.nd'::regclass),
  '>=', 3500::bigint, 'obtain keeps the grid ahead of the frontier as it advances');

-- obtain is now pure metadata: with no DEFAULT there is nothing to prove empty, so no constraint dance.
select is((select count(*)::int from pgpm.log
            where parent_table = 'public.nd'::regclass and action = 'obtain' and method = 'check_skip'),
  0, 'and does it with no exclusion-constraint dance, because there is no DEFAULT to prove empty');

-- ============================ the drain is gone ============================
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'pgpm' and p.proname in
                  ('drain_step','drain_all','check_default','_ambient_baseline_next')),
  0, 'the drain and everything that served it are gone, not merely unused');

-- suspend_incoming_fks SURVIVES, with a much narrower remit. maintain used to call it before every drain,
-- dropping the FK for a whole multi-tick campaign, which is the RI window this change removes. regrain's
-- swap still needs it, but suspends and restores inside its own transaction, so no session observes RI off.
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'pgpm' and p.proname = 'suspend_incoming_fks'),
  1, 'but suspend_incoming_fks stays: regrain''s swap needs it, within one transaction');

-- ============================ a maintenance tick still works end to end ============================
call pgpm.maintain('public.nd') \gset
select ok(:'p_status' not like '%drain%',
  'a maintenance tick no longer has a drain step at all');

select * from finish();
