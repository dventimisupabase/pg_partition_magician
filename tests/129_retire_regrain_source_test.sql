-- retire() dropping the coarse SOURCE of an in-flight regrain must take the regrain's state with it, and
-- must take nothing else (issue #519).
--
-- With auto-regrain, an archive_fn and retention all on (the fully scheduled path), two pipelines work
-- the same wholly-aged coarse child at once: the archive step covers it chunk by chunk so that retire
-- can drop it whole, and regrain copies it sub-range by sub-range so that the swap can replace it.
-- Whichever finishes first wins. When archiving won, retire dropped the source and left everything the
-- regrain had built behind: not-attached pgpm.part rows that no partition covers, real tables still
-- holding the rows retention just "dropped", config.regrain_cursor pointing into a range that no
-- longer exists, and no later tick able to reclaim any of it (auto-regrain answers 'none', the
-- janitor only tears down capture the cursor does not cover, and regrain_cancel is an operator verb).
--
-- The fix is scoped reclamation at the drop, not a refusal: a wholly-aged coarse child drops in one
-- step (the documented retain contract), and every fine child the regrain would have produced would be
-- retire-eligible the moment it attached, so the regrain has nothing left to achieve. retire discards
-- the copies inside the dropped range, the captured changes whose only consumer was those copies, and
-- the cursor, in the same subtransaction as the DROP, and logs one regrain_cancel row saying so. Scoped
-- to THIS source: a regrain in flight on another child of the same parent is untouched, and a retire
-- that refuses (coverage incomplete) reclaims nothing.
--
-- Every negative below ("no orphan", "nothing left", "untouched") is paired with a witness that the
-- state it denies really existed first, so a run in which the regrain never copied anything cannot
-- pass it (CLAUDE.md, assertions that pass for the wrong reason).
create extension if not exists pgtap;
select plan(42);

-- ============================ A: the scheduled path (the issue's reproduction) ============================
create table public.rrs_a (id bigint primary key, payload text);
insert into public.rrs_a select g, repeat('x', 100) from generate_series(1, 2000) g;       -- monolith [0,3000)
call pgpm.transmute('public.rrs_a', 'id', 1000, p_retain => 1000::bigint, p_paused => false);
insert into public.rrs_a values (20000, 'frontier');                                       -- horizon 19000
select pgpm.set_archive_fn('public.rrs_a', 'pgpm._archive_noop(regclass,name,text,text)');
update pgpm.config set archive_byte_budget = 60000 where parent_table = 'public.rrs_a'::regclass;  -- a few chunks
select pgpm.set_regrain('public.rrs_a', '100');                                            -- auto-regrain on

-- Tick until retention drops the monolith, snapshotting the regrain's copies BEFORE each tick: within a
-- tick retain runs before regrain_step, so the snapshot taken before the dropping tick is exactly the set
-- of copies that were in flight when retire dropped their source. That set is what the defect orphaned.
create temp table rrs_a_copies (child_name name);
do $$ declare v text; i int := 0; begin
  loop
    delete from rrs_a_copies;
    insert into rrs_a_copies select child_name from pgpm.part where parent_table = 'public.rrs_a'::regclass and not attached;
    call pgpm.maintain('public.rrs_a', v);
    i := i + 1;
    exit when exists (select 1 from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'retain_drop' and lo = '0')
          or i >= 40;
  end loop;
end $$;

-- liveness: both machines really worked the monolith, and archiving won
-- Expected: 0, 100, ... up to the number of copies logged, and a sentinel when fewer than two were, so
-- a run that copied nothing (array_agg over no rows is null) cannot match a null expectation.
select is((select array_agg(lo::numeric order by lo::numeric) from pgpm.log
            where parent_table = 'public.rrs_a'::regclass and action = 'regrain_copy'),
          (select case when n >= 2 then (select array_agg(g::numeric) from generate_series(0, 100 * (n - 1), 100) g)
                       else array[-1]::numeric[] end
             from (select count(*)::int as n from pgpm.log
                    where parent_table = 'public.rrs_a'::regclass and action = 'regrain_copy') c),
          'LIVENESS: auto-regrain copied at least the monolith''s first two sub-ranges, contiguously from 0');
select is((select array_agg(child_name::text order by child_name) from rrs_a_copies),
          (select array_agg(format('rrs_a_p%s', lpad(lo, 19, '0')) order by lo::numeric) from pgpm.log
            where parent_table = 'public.rrs_a'::regclass and action = 'regrain_copy'),
          'LIVENESS: one standalone copy per copied sub-range was in flight when retire reached the source');
select is((select max(hi::numeric) from pgpm.archive_ledger
            where parent_table = 'public.rrs_a'::regclass
              and child_name = 'rrs_a_p0000000000000000000_to_0000000000000003000'),
          3000::numeric, 'LIVENESS: archiving covered the monolith whole, which is what let retire drop it');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'retain_drop' and lo = '0' and hi = '3000'),
          'LIVENESS: retention dropped the monolith');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'regrain'),
          0, 'LIVENESS: the regrain never reached its swap, so the source was dropped mid-flight by retire, not by regrain');
select ok((select max(id) from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'regrain_copy')
        < (select id from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'retain_drop' and lo = '0'),
          'LIVENESS: every copy predates the drop');

-- the defect: nothing the regrain built outlives its source
select is((select array_agg(cp.child_name::text order by cp.child_name) from pgpm.part cp
            where cp.parent_table = 'public.rrs_a'::regclass and not cp.attached),
          null, 'no not-attached pgpm.part row remains for the parent');
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
              and c.relname = any (select child_name from rrs_a_copies)),
          null, 'the copies that were in flight at the drop no longer exist as relations');
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname ~ '^rrs_a_p[0-9]{19}$'
              and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)),
          null, 'no standalone copy table of any kind is left in the schema');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rrs_a'::regclass),
          null, 'config.regrain_cursor no longer points into the dropped source');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname in ('pgpm_regrain_capture', 'pgpm_regrain_truncate_guard')
              and c.relnamespace = 'public'::regnamespace and c.relname like 'rrs\_a%'),
          0, 'no change-capture trigger is left on any relation of the parent');
select is((select array_agg(row(lo, hi, rows, method like '%retire%')::text) from pgpm.log
            where parent_table = 'public.rrs_a'::regclass and action = 'regrain_cancel'),
          array[row('0', '3000', (select count(*) from rrs_a_copies), true)::text],
          'retire logged exactly one regrain_cancel for the source, counting the copies it discarded and naming itself');
select ok((select id from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'regrain_cancel')
        < (select id from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'retain_drop' and lo = '0'),
          'the cancel is recorded before the drop it makes room for, in the same tick');
select is((select array_agg(id order by id) from public.rrs_a), array[20000]::bigint[],
          'the parent holds exactly the frontier row: the monolith''s rows went through the archive, not into an orphan');
select ok(exists (select 1 from pgpm.archive_ledger where parent_table = 'public.rrs_a'::regclass
                    and child_name = 'rrs_a_p0000000000000000000_to_0000000000000003000'),
          'the source''s archive coverage stays in the ledger as the record of where its rows went');

-- and the parent is quiet afterwards: no tick trips over what the regrain left, because nothing was left
do $$ declare v text; begin for i in 1..3 loop call pgpm.maintain('public.rrs_a', v); end loop; end $$;
select is((select array_agg(distinct action order by action) from pgpm.log
            where parent_table = 'public.rrs_a'::regclass
              and id > (select id from pgpm.log where parent_table = 'public.rrs_a'::regclass and action = 'retain_drop' and lo = '0')
              and action not in ('retain_drop')),
          null, 'the ticks after the drop log nothing but further retention (no skip_, fail_ or regrain_ rows)');
select is((select inflight_partitions from pgpm.status() where parent = 'public.rrs_a'::regclass),
          0::bigint, 'status() reports no in-flight partition for the parent');
select is((select regrain_child from pgpm.progress('public.rrs_a')), null,
          'progress() reports no regrain in flight');

-- ============================ B: retire() by hand, with a captured change still pending ============================
-- The same reclamation on the direct path, and with something in the delta, so "the delta is empty"
-- afterwards has a witness. Paused: no maintenance tick touches this table, every step is explicit.
create table public.rrs_b (id bigint primary key, payload text);
insert into public.rrs_b select g, repeat('x', 100) from generate_series(1, 2000) g;
call pgpm.transmute('public.rrs_b', 'id', 1000, p_retain => 1000::bigint, p_paused => true);
insert into public.rrs_b values (20000, 'frontier');
select pgpm.set_archive_fn('public.rrs_b', 'pgpm._archive_noop(regclass,name,text,text)');
update pgpm.config set archive_byte_budget = 8 * 1024 * 1024 where parent_table = 'public.rrs_b'::regclass;  -- one chunk covers

select is(pgpm.regrain_step('public.rrs_b', 'rrs_b_p0000000000000000000_to_0000000000000003000', '100', 500),
          'prepared', 'LIVENESS: a regrain of the monolith is in flight (capture installed)');
select is(pgpm.regrain_step('public.rrs_b', 'rrs_b_p0000000000000000000_to_0000000000000003000', '100', 500),
          'copied:99', 'LIVENESS: [0,100) copied');
select is(pgpm.regrain_step('public.rrs_b', 'rrs_b_p0000000000000000000_to_0000000000000003000', '100', 500),
          'copied:100', 'LIVENESS: [100,200) copied');
update public.rrs_b set payload = 'changed' where id = 5;   -- no write block yet: captured, not refused
select is(pgpm._regrain_delta_count('public.rrs_b'), 2::bigint,
          'LIVENESS: one captured change (its OLD and NEW key) is pending in the delta');
select is((select array_agg(child_name::text order by child_name) from pgpm.part
            where parent_table = 'public.rrs_b'::regclass and not attached),
          array['rrs_b_p0000000000000000000', 'rrs_b_p0000000000000000100'],
          'LIVENESS: the two fine copies exist, not attached');
select pgpm._enforce_write_blocks('public.rrs_b');
select pgpm._archive_step('public.rrs_b');
select ok(pgpm._archive_fully_covered('public.rrs_b', 'rrs_b_p0000000000000000000_to_0000000000000003000'),
          'LIVENESS: archiving covers the monolith, so retire will drop it');

select is(pgpm.retire('public.rrs_b', 'rrs_b_p0000000000000000000_to_0000000000000003000'), true,
          'retire drops the wholly-aged source in one step, regrain or no regrain (the documented retain contract)');

select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
              and c.relname in ('rrs_b_p0000000000000000000', 'rrs_b_p0000000000000000100')),
          null, 'both fine copies are gone as relations');
select is((select array_agg(child_name::text order by child_name) from pgpm.part
            where parent_table = 'public.rrs_b'::regclass and not attached),
          null, 'and as pgpm.part rows');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rrs_b'::regclass),
          null, 'the cursor is cleared');
select is(pgpm._regrain_delta_count('public.rrs_b'), 0::bigint,
          'the captured change is discarded with the copies it was for (the source, its authority, is archived and dropped)');
select is((select array_agg(row(lo, hi, rows)::text) from pgpm.log
            where parent_table = 'public.rrs_b'::regclass and action = 'regrain_cancel'),
          array[row('0', '3000', 2)::text],
          'one regrain_cancel row, for the source''s range, counting both copies');
select ok((select method from pgpm.log where parent_table = 'public.rrs_b'::regclass and action = 'regrain_cancel')
          like '%retire%',
          'and its method says retire did it');
select is((select array_agg(id order by id) from public.rrs_b), array[20000]::bigint[],
          'the parent holds exactly the frontier row');

-- ============================ C: scoped to the source; a refusal reclaims nothing ============================
-- A regrain in flight on the monolith while retire drops a DIFFERENT wholly-aged partition of the same
-- parent, and while retire REFUSES the monolith itself (coverage incomplete): neither may touch the
-- regrain. Then the regrain completes, and the captured change it was carrying is honoured, which is
-- the only proof that "untouched" meant the delta too.
create table public.rrs_c (id bigint primary key, payload text);
insert into public.rrs_c select g, repeat('x', 100) from generate_series(1, 2000) g;
call pgpm.transmute('public.rrs_c', 'id', 1000, p_retain => 1000::bigint, p_paused => true);
insert into public.rrs_c values (20000, 'frontier');
select pgpm.set_archive_fn('public.rrs_c', 'pgpm._archive_noop(regclass,name,text,text)');
-- a tiny budget keeps the monolith UNcovered; archive_batch 2 lets the empty [3000,4000) cover in the same call
update pgpm.config set archive_byte_budget = 2000, archive_batch = 2 where parent_table = 'public.rrs_c'::regclass;

select is(pgpm.regrain_step('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000', '100', 500),
          'prepared', 'LIVENESS: a regrain of the monolith is in flight');
select pgpm.regrain_step('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000', '100', 500);
select pgpm.regrain_step('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000', '100', 500);
update public.rrs_c set payload = 'changed' where id = 1500;
select is((select array_agg(child_name::text order by child_name) from pgpm.part
            where parent_table = 'public.rrs_c'::regclass and not attached),
          array['rrs_c_p0000000000000000000', 'rrs_c_p0000000000000000100'],
          'LIVENESS: two copies in flight, cursor at 200');
select pgpm._enforce_write_blocks('public.rrs_c');
select pgpm._archive_step('public.rrs_c');
select ok(pgpm._archive_fully_covered('public.rrs_c', 'rrs_c_p0000000000000003000')
          and not pgpm._archive_fully_covered('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000'),
          'LIVENESS: the neighbour [3000,4000) is covered and the monolith is not');

select is(pgpm.retire('public.rrs_c', 'rrs_c_p0000000000000003000'), true,
          'retire drops the covered neighbour');
select is(pgpm.retire('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000'), false,
          'and refuses the monolith, whose coverage is incomplete');

select is((select row(regrain_cursor,
                      (select array_agg(child_name::text order by child_name) from pgpm.part
                        where parent_table = 'public.rrs_c'::regclass and not attached),
                      pgpm._regrain_capture_active('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000'),
                      pgpm._regrain_delta_count('public.rrs_c'))::text
             from pgpm.config where parent_table = 'public.rrs_c'::regclass),
          row('200', array['rrs_c_p0000000000000000000', 'rrs_c_p0000000000000000100'], true, 2::bigint)::text,
          'neither the neighbour''s drop nor the refusal touched the regrain: cursor, copies, capture and delta are as they were');
select is((select array_agg(action order by id) from pgpm.log
            where parent_table = 'public.rrs_c'::regclass and action in ('regrain_cancel', 'retain_drop')),
          array['retain_drop'], 'one retain_drop (the neighbour) and no regrain_cancel');

do $$ declare v_status text; i int := 0; begin
  loop
    v_status := pgpm.regrain_step('public.rrs_c', 'rrs_c_p0000000000000000000_to_0000000000000003000', '100', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or i > 300;
  end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.rrs_c'::regclass and action = 'regrain'),
          'LIVENESS: the regrain went on to swap');
select is((select array_agg(g) from generate_series(1, 2000) g
            where not exists (select 1 from public.rrs_c where id = g)),
          null, 'every monolith row is still readable through the parent after the swap');
select is((select payload from public.rrs_c where id = 1500), 'changed',
          'and the change captured mid-regrain was reconciled, so the delta really was left alone');

select * from finish();
