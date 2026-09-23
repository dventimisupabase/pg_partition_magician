-- from_hypertable_cutover locked a name and then DROPped it, without verifying the oid (issue #422).
--
-- The cutover resolves p_hypertable to a name pair once, near the top, then does a substantial amount
-- of work before locking anything, and only then `lock table <nsp>.<rel> in access exclusive mode`,
-- `drop table <nsp>.<rel>`, and `alter table <dest> rename to <rel>`. LOCK TABLE locks whatever the
-- name meant at lock time; nothing re-resolved it afterwards and compared it to p_hypertable.
--
-- WHICH WINDOW ACTUALLY MATTERS, because most of the span is self-protecting:
--
--   * A rename landing before the cutover starts is caught by the `found no copy to cut over` check:
--     the staging names derive from the source's name, so they stop resolving.
--   * A rename landing during the online pre-drain is caught too, but by a mechanism the issue did
--     not name: from_hypertable_drain_delta_step / _drain_appends_step each RE-RESOLVE the name per
--     batch, so the next batch raises `found no delta`. The pre-drain commits per batch and so looks
--     like the widest part of the window; it is in fact the safest.
--   * That leaves the index pre-builds -- explicitly the O(rows) work the cutover moved OUT of the
--     lock to keep the outage brief, so the LONGEST stretch of the window -- with nothing in it that
--     re-resolves the source. This file exercises exactly that stretch.
--
-- THE LEVER IS AN EVENT TRIGGER, NOT A RACE. The substitution has to land between the name resolution
-- and the lock, which is inside one procedure call; a second session timed to hit it would be exactly
-- the poll-then-race probe this project has been bitten by. An event trigger on CREATE INDEX fires
-- deterministically in that window, because the index pre-builds are what is running there.
--
-- WHAT THE HARNESS ALLOWS, and why the assertions look the way they do. run_timescale fails the track
-- on any `ERROR:` line, so the cutover must be wrapped by throws_like -- and a procedure that reaches
-- its own COMMIT inside a function raises `invalid transaction termination`. So a run that WRONGLY
-- succeeds cannot be observed committing: it dies at its commit and rolls back, landing in the same
-- end state as a correct refusal. The discriminating assertion is therefore the refusal's own message,
-- matched exactly; the state assertions after it are invariants, not discriminators, and are marked so.
-- The one thing that must survive the rollback is proof the lever fired at all, so that is witnessed
-- through a SEQUENCE, whose nextval is non-transactional.
select plan(16);

create table t17_lever (target text, extra text);
create sequence t17_fired;

create function t17_substitute() returns event_trigger language plpgsql as $$
declare r record;
begin
  select * into r from t17_lever;
  if not found or r.target is null then return; end if;
  if nextval('t17_fired') <> 1 then return; end if;   -- once per arming; survives the rollback
  execute format('alter table public.%I rename to %I', r.target, r.target || '_moved');
  execute format('create table public.%I (like public.%I)', r.target, r.target || '_moved');
  if r.extra is not null then execute r.extra; end if;
end $$;

-- ddl_command_START, not _end, and it matters for part B: firing before the statement runs means the
-- cutover's own CREATE INDEX resolves its target AFTER the swap and so builds the temp index on the
-- impostor. At _end the real destination already owns that index name, and since index names are
-- schema-scoped the fixture could not give the impostor one without a collision -- so a mutant would
-- die on `relation "..._pgpm_new" already exists` instead of on the identity it is supposed to miss.
create event trigger t17_et on ddl_command_start when tag in ('CREATE INDEX')
  execute function t17_substitute();

-- nextval is NOT transactional, so this is the one fact about the attempt that survives the rollback
-- every path here ends in. pg_sequences.last_value reads null until the sequence is first read, and
-- again after RESTART, so null/not-null is exactly "the lever fired".
create function t17_fired() returns boolean language sql as $$
  select (select last_value from pg_sequences where sequencename = 't17_fired') is not null;
$$;

-- ================= PART A: the SOURCE is substituted inside the index-build window =================

select mk_keyed_hypertable('hc17a', 60, '1 day', '10 days');
call pgpm.from_hypertable_copy('hc17a', 'ts');

select is((select count(*)::int from hc17a), 60, 'setup: the source holds its 60 rows');
select is((select count(*)::int from hc17a_pgpm_dest), 60, 'setup: the copy phase produced a populated destination');
select ok(not t17_fired(), 'setup: the lever has not fired yet');

-- arm it: the next CREATE INDEX renames the source aside and puts a plain impostor under its name
insert into t17_lever values ('hc17a', null);

-- p_predrain => false so no COMMIT is reached before the refusal (the pre-drain commits per batch,
-- and a COMMIT inside throws_like's function context would raise for an unrelated reason).
select throws_like(
  $$ call pgpm.from_hypertable_cutover('hc17a', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to drop a relation it did not identify%',
  'the cutover refuses: the name it resolved no longer means the hypertable it was called for');

-- LIVENESS. Everything above and below is satisfied by a run in which the substitution never happened
-- and the cutover failed for some unrelated reason. nextval is non-transactional, so this survives the
-- rollback that the refusal (and, on a mutant, the commit failure) triggers.
select ok(t17_fired(),
  'LIVENESS: the event trigger really fired inside the index-build window');

-- The refusal rolls the whole cutover back, so the substitution is undone with it. These say the
-- source survived the attempt whole -- an invariant worth pinning, not a discriminator (a mutant
-- rolls back too, at its own COMMIT).
select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hc17a'),
  1, 'the source is still a hypertable: the swap transaction rolled back whole');
select is((select count(*)::int from hc17a), 60, 'with all 60 of its rows');
select ok(to_regclass('public.hc17a_pgpm_dest') is not null,
  'and the destination is still the destination -- it was not renamed into the source''s name');
select ok(to_regclass('public.hc17a_moved') is null,
  'and the rename the lever made is gone with the rollback');

-- ================= PART B: the DESTINATION is substituted in the same window =================
--
-- The other half of the same swap, and the one that ends with an unverified relation BECOMING the
-- production table rather than merely being dropped. The destination is existence-checked at the top
-- of the cutover but never identity-checked, and nothing locks it until the first CREATE INDEX -- and
-- the pre-drain's commits release even that.
--
-- SCOPE, stated honestly: capturing the oid at that existence check closes the window from there to
-- the swap. It cannot see a destination that was already substituted BEFORE the cutover was called,
-- because the module keeps no persistent record of what it built. That would need the module-wide oid
-- recording #422 describes and this change deliberately does not do.
--
-- The impostor is made CONVINCING on purpose -- same columns, and the temp-named index the swap
-- adopts -- so a mutant gets all the way to the swap instead of tripping over a missing index and
-- failing for a reason that has nothing to do with identity. It carries FEWER rows than the real
-- destination, so the two can never be mistaken for one another.
select mk_keyed_hypertable('hc17b', 40, '1 day', '10 days');
call pgpm.from_hypertable_copy('hc17b', 'ts');

select is((select count(*)::int from hc17b_pgpm_dest), 40, 'setup: the real destination holds 40 rows');

alter sequence t17_fired restart;
update t17_lever set target = 'hc17b_pgpm_dest',
  extra = $x$ insert into public.hc17b_pgpm_dest
                 select * from public.hc17b_pgpm_dest_moved limit 7 $x$;

select throws_like(
  $$ call pgpm.from_hypertable_cutover('hc17b', 'ts', interval '1 month', p_predrain => false) $$,
  '%refusing to rename an unverified relation%',
  'the cutover refuses: the destination it is about to rename into place is not the one it found');

select ok(t17_fired(),
  'LIVENESS: the event trigger fired for the destination too');

select is((select count(*)::int from timescaledb_information.hypertables where hypertable_name = 'hc17b'),
  1, 'the source is still a hypertable: it was not dropped for an unverified replacement');
select is((select count(*)::int from hc17b), 40, 'with all 40 of its rows');
select is((select count(*)::int from hc17b_pgpm_dest), 40,
  'and the destination is the real one, with its own 40 rows -- not the 7-row impostor');
select ok(to_regclass('public.hc17b_pgpm_dest_moved') is null,
  'the substitution is gone with the rollback');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
