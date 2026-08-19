-- p_lock_timeout (#309). transmute takes ACCESS EXCLUSIVE twice on the operator's live table (phase 1's
-- ADD CONSTRAINT, phase 3's RENAME) and used to wait for it indefinitely -- and a PENDING AccessExclusive
-- blocks every lock request queued behind it, so one long-running query turned the wait into an outage of
-- the whole table.
--
-- The LOCK BEHAVIOUR itself cannot be asserted here: it needs a second session holding a conflicting lock
-- while a first attempts the conversion, and pgTAP gives one session per file. That lives in
-- bench/transmute_lock_timeout.sh, with a mutation in bench/mutations/ proving it discriminates.
--
-- What IS assertable here, and is not covered there: the parameter's own contract. A bad value must be
-- refused UP FRONT, before anything is committed, rather than from inside phase 1 or -- far worse --
-- phase 3, after the operator has already waited through the O(rows) validation scan.
create extension if not exists pgtap;

select plan(6);

create table public.lt (id bigint, created_at timestamptz not null default now(), payload text,
                        primary key (created_at, id));
insert into public.lt (id, created_at, payload)
  select g, now() - (g || ' minutes')::interval, 'x' from generate_series(1, 200) g;

-- session-scoped, not ON COMMIT DROP: each statement here commits on its own (the suite isolates per
-- database, not per transaction), so an ON COMMIT DROP table would vanish before the next statement.
create table pg_temp.lt_before as select current_setting('lock_timeout') as v;

select throws_ok(
  $$ call pgpm.transmute('public.lt', 'created_at', interval '1 day', p_lock_timeout => 'not-a-duration') $$,
  'P0001', null,
  'a bad p_lock_timeout is refused');

-- The refusal must leave NOTHING behind. This is what distinguishes "validated up front" from "validated
-- inside phase 1": a phase-1 failure would already have committed the inflight row and the bound CHECK,
-- leaving the operator a table that refuses out-of-range writes until someone aborts the conversion.
select is((select relkind::text from pg_class where oid = 'public.lt'::regclass), 'r',
  'the table is untouched after the refusal');
select is((select count(*) from pgpm.transmute_inflight), 0::bigint,
  'no in-flight record was recorded');
select ok(not exists (select 1 from pg_constraint
                       where conrelid = 'public.lt'::regclass and conname = 'pgpm_monolith_bound'),
  'no bound CHECK was left on the table');

call pgpm.transmute('public.lt', 'created_at', interval '1 day', p_lock_timeout => '3s');

select is((select relkind::text from pg_class where oid = 'public.lt'::regclass), 'p',
  'a valid p_lock_timeout converts normally');

-- Validating the parameter must not double as applying it. If the check left the setting in place, the
-- per-phase set_config calls would be doing nothing observable and the mutation that proves
-- bench/transmute_lock_timeout.sh discriminates would produce a mutant its guard still passed against.
select is(current_setting('lock_timeout'), (select v from pg_temp.lt_before),
  'the caller''s lock_timeout is unchanged afterwards');

select * from finish();
