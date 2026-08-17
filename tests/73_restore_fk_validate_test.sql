-- restore_incoming_fks re-adds NOT VALID and stops; maintenance finishes the validation later (#265).
--
-- The ADD and the VALIDATE used to share a transaction, so the ADD's SHARE ROW EXCLUSIVE was held over
-- the VALIDATE's scan of the referencing table. SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so that
-- blocked writes on the MANAGED PARENT for a duration proportional to a table pgpm does not even own.
--
-- The lock behaviour is in bench/restore_fk_lock.sh (./test.sh perf), which needs two sessions. This file
-- pins the consequences of splitting them: what state the FK is in between the two halves, that it is
-- already enforcing writes in that state, and that maintenance closes it out without the operator.
--
-- Why not just leave it NOT VALID: an unvalidated FK enforces every NEW write but leaves pre-existing
-- rows unverified, and status().fks_unvalidated exists precisely because that is a state an operator has
-- to be told about. Finishing it automatically keeps today's end state.
create extension if not exists pgtap;
select plan(10);

create table public.m73 (id bigint primary key, body text);
insert into public.m73 select g, 'x' from generate_series(1, 3000) g;
create table public.r73 (id bigint primary key,
  message_id bigint not null references public.m73(id), v text);
insert into public.r73 select g, ((g % 3000) + 1), 'r' from generate_series(1, 5000) g;

call pgpm.transmute('public.m73', 'id', 3000, p_incoming_fks => 'preserve', p_paused => false);

select is((select count(*)::int from pg_constraint
            where conrelid = 'public.r73'::regclass and contype = 'f' and conparentid = 0),
  0, 'transmute with preserve drops the incoming FK and records it');

-- ============================ the restore re-adds, and stops ============================
select is(pgpm.restore_incoming_fks('public.m73'), 1, 'restore re-adds the FK');

select ok(not (select convalidated from pg_constraint
                where conrelid = 'public.r73'::regclass and contype = 'f' and conparentid = 0),
  'and leaves it NOT VALID rather than scanning the referencing table under the ADD''s lock');

select is((select count(*)::int from pgpm.dropped_fk
            where parent_table = 'public.m73'::regclass and restored_at is not null and validated_at is null),
  1, 'which is recorded as restored-but-unvalidated, the state status() reports');

select cmp_ok((select fks_unvalidated from pgpm.status() where parent = 'public.m73'::regclass), '>', 0::bigint,
  'and surfaced by status().fks_unvalidated so it is never silently half-done');

-- The point of NOT VALID: RI is live for new writes immediately. Behavioural, not structural -- an
-- assertion that the constraint merely EXISTS would pass even if it enforced nothing.
select throws_ok($$ insert into public.r73 values (999999, 88888, 'orphan') $$, '23503', NULL,
  'an unvalidated FK still REJECTS a new orphan: RI is live from the moment it is re-added');

-- ============================ maintenance finishes it ============================
call pgpm.maintain('public.m73');

select ok((select convalidated from pg_constraint
            where conrelid = 'public.r73'::regclass and contype = 'f' and conparentid = 0),
  'a later maintenance tick validates it, with no operator action');

select is((select fks_unvalidated::int from pgpm.status() where parent = 'public.m73'::regclass), 0,
  'and status().fks_unvalidated goes back to zero');

-- ============================ an orphan-blocked FK backs off ============================
-- A VALIDATE that fails re-scans the whole referencing table. Retrying that every tick is the exact
-- concern the code comments record, so a failure sets a retry window instead.
create table public.m73b (id bigint primary key, body text);
insert into public.m73b select g, 'x' from generate_series(1, 3000) g;
create table public.r73b (id bigint primary key,
  message_id bigint not null references public.m73b(id), v text);
insert into public.r73b select g, ((g % 3000) + 1), 'r' from generate_series(1, 5000) g;
call pgpm.transmute('public.m73b', 'id', 3000, p_incoming_fks => 'preserve', p_paused => false);
-- Written while the FK is suspended: exactly the orphan the preserve lifecycle admits can happen.
insert into public.r73b values (999999, 88888, 'orphan written during the suspend window');
select pgpm.restore_incoming_fks('public.m73b');

call pgpm.maintain('public.m73b');

select ok(not (select convalidated from pg_constraint
                where conrelid = 'public.r73b'::regclass and contype = 'f' and conparentid = 0),
  'an FK blocked by a pre-existing orphan stays NOT VALID rather than being rolled back to dropped');

select cmp_ok((select validate_retry_after from pgpm.dropped_fk
                where parent_table = 'public.m73b'::regclass), '>', now(),
  'and a retry window is set, so it does not re-scan the referencing table on every tick');

select * from finish();
