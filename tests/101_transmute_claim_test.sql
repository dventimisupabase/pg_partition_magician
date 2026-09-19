-- transmute's claim protocol (issue #405): the pgpm.transmute_inflight row IS the exclusion, and the
-- claiming session's recorded identity is what makes it releasable without a heartbeat.
--
-- This replaced a session advisory lock keyed on hashtextextended('pgpm_transmute:' || oid). That key
-- carried no ACL and was computable by anyone, so any role that could merely CONNECT could hold it and
-- block every transmute of a table, or starve the reaper by grabbing it the instant a crashed conversion
-- released it. Proving THAT is impossible in one session -- it needs a second, concurrent squatter -- so
-- it lives in bench/transmute_claim_squat.sh with a mutation that puts the defect back. What this file
-- pins is the part that is expressible in one session: the claim's own state machine, and the liveness
-- predicate the recovery paths read.
create extension if not exists pgtap;

select plan(10);

-- ---------------------------------------------------------------------------
-- pgpm._session_alive: the liveness predicate
-- ---------------------------------------------------------------------------

-- Our own session is trivially alive, and this is the WITNESS for the negative cases below: without it,
-- every "not alive" assertion here would be equally satisfied by a predicate that is simply always false.
select ok(pgpm._session_alive(pg_backend_pid(),
                              (select backend_start from pg_stat_activity where pid = pg_backend_pid())),
          'a live session with a matching backend_start reads as alive');

-- The degradation that makes cross-role safe. backend_start is MASKED (reads NULL) for a backend owned by
-- another role, and the reaper runs under whatever role scheduled its cron job. Matching on pid alone when
-- backend_start is not visible is what keeps a live cross-role conversion from being reaped out from under
-- itself; here the column IS visible, so a deliberately wrong backend_start must NOT match.
select ok(not pgpm._session_alive(pg_backend_pid(), '1970-01-01'::timestamptz),
          'a matching pid with a non-matching visible backend_start is not alive');

select ok(not pgpm._session_alive(null, now()),
          'a claim with no recorded owner is not alive (covers pre-#405 rows and test fixtures)');

-- A pid that belongs to no backend at all. max_connections is far below this, so it cannot be live.
select ok(not pgpm._session_alive(2147483647, now()),
          'a pid belonging to no backend is not alive');

-- ---------------------------------------------------------------------------
-- The claim's state machine
-- ---------------------------------------------------------------------------

create table public.cl0 (id bigint primary key, ts timestamptz not null);
insert into public.cl0 select g, now() from generate_series(1, 50) g;

-- A fresh conversion records a claim naming THIS session as its owner.
call pgpm.transmute('public.cl0', 'id', 100::bigint, p_paused => true);
select is((select count(*)::int from pgpm.transmute_inflight where parent_table = 'public.cl0'::regclass),
          0, 'a completed conversion releases its claim by deleting the row');

-- A claim whose owner is alive refuses a second conversion. Built by hand rather than by racing two real
-- transmutes, which one session cannot do: the row plus a live owner IS the state a running conversion
-- presents, and it is exactly what _transmute's ON CONFLICT ... WHERE NOT _session_alive(...) consults.
create table public.cl1 (id bigint primary key);
insert into pgpm.transmute_inflight (parent_table, nsp, rel, control_kind, lo, hi,
                                     owner_pid, owner_backend_start)
values ('public.cl1'::regclass, 'public', 'cl1', 'id', '0', '100',
        pg_backend_pid(), (select backend_start from pg_stat_activity where pid = pg_backend_pid()));

select ok(pgpm._session_alive(owner_pid, owner_backend_start),
          'the constructed claim really does have a live owner (witness for the refusals below)')
  from pgpm.transmute_inflight where parent_table = 'public.cl1'::regclass;

select throws_ok(
  $$ call pgpm.transmute('public.cl1', 'id', 100::bigint) $$,
  null,
  'pg_partition_magician: a transmute of cl1 is already in progress in another session',
  'a live claim refuses a second conversion');

-- ...and the reaper and the manual escape hatch both leave a live claim alone.
select is(pgpm._transmute_reap(), 0, 'the reaper does not touch a claim whose owner is alive');
select throws_ok(
  $$ select pgpm.transmute_abort('public.cl1') $$,
  null,
  'pg_partition_magician: cannot abort the transmute of cl1 -- it is still running in another session',
  'transmute_abort refuses a claim whose owner is alive');

-- THE DISCRIMINATOR. Same row, same table, owner cleared to stand in for a session that died mid-run: the
-- reaper must now undo it. Without this the four assertions above are all satisfied by a reaper that never
-- reaps anything at all.
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.cl1'::regclass;
select is(pgpm._transmute_reap(), 1, 'the reaper DOES undo the same claim once its owner is gone');

select * from finish();
