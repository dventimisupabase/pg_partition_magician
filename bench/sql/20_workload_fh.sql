-- Server-side workload for the from_hypertable track. One call performs p_ops time-keyed operations, so a
-- single client round-trip drives many ops (the SERVER is the bottleneck, not the WAN). References
-- bench.events by name, so it is identical against the live hypertable (baseline), during the migration
-- (convert), and against the pgpm-partitioned table (post).
--
-- Two design points that make the at-scale from_hypertable measurement honest:
--   1. EVERY query filters by user_id (the lookup index) AND a recent created_at window, so reads/writes
--      PRUNE to recent chunks (hypertable) / partitions (pgpm) -- stable cost before and after.
--   2. CONSERVATION ANCHOR. The workload only ever touches users 1..49000; users 49001..50000 are a
--      reserved IMMUTABLE cohort (generated across all of history, so across all chunks). The harness
--      verifies that cohort survives the online migration unchanged -- a clean conservation check under
--      continuous insert/update/delete load (an exact total-count check is impossible while the workload
--      mutates rows). The update/delete ops still exercise from_hypertable's p_track_changes path at scale.
--
-- Mix: 35% head insert (+ companion upsert), 30% recent read (newest 20), 15% wider recent count,
--      12% UPDATE a recent row (track_changes UPDATE), 8% DELETE a recent row (track_changes DELETE).
-- p_clock_secs shifts the workload's effective "now" forward by that many seconds. The phases that run
-- against the live/normal head pass 0 (real now()). The REFINE phase passes a positive offset that pushes
-- the effective clock PAST the migrated monolith's upper bound, so the workload's writes land in FORWARD
-- partitions (not the frozen historical monolith) -- the condition that lets pgpm refine the monolith under
-- ongoing load (a time monolith cannot freeze while current-period writes still target its range).
create or replace function bench.workload_step_fh(p_ops int default 10, p_clock_secs bigint default 0)
returns void language plpgsql as $$
declare
  v_maxuser int := 49000;             -- workload touches users 1..49000; 49001..50000 = immutable anchor
  v_win     interval := interval '7 days';   -- "recent" window reads/writes target (prunes to recent chunks)
  v_clock   timestamptz := now() + (p_clock_secs || ' seconds')::interval;   -- effective "now" (shiftable)
  r       double precision;
  uid     int;
  newid   bigint;
  v_id    bigint;
  v_ts    timestamptz;
  i       int;
begin
  for i in 1 .. p_ops loop
    r   := random();
    uid := 1 + floor(random() * v_maxuser)::int;
    if r < 0.35 then
      insert into bench.events (created_at, user_id, kind, payload)
      values (v_clock, uid, floor(random() * 8)::smallint,
              substr(md5(random()::text) || md5(random()::text) || md5(random()::text), 1, 200))
      returning id into newid;
      insert into bench.user_seen (user_id, last_event, seen_at) values (uid, newid, now())
      on conflict (user_id) do update set last_event = excluded.last_event, seen_at = excluded.seen_at;
    elsif r < 0.65 then
      perform count(*) from (
        select id from bench.events
        where user_id = uid and created_at >= v_clock - v_win
        order by created_at desc limit 20
      ) s;
    elsif r < 0.80 then
      perform count(*) from bench.events
      where user_id = uid and created_at >= v_clock - v_win;
    elsif r < 0.92 then
      -- UPDATE a recent row's payload (never the key columns id/created_at). Resolve the full key first so
      -- the UPDATE carries a created_at equality and prunes to one chunk/partition.
      select id, created_at into v_id, v_ts from bench.events
        where user_id = uid and created_at >= v_clock - v_win order by created_at desc limit 1;
      if found then
        update bench.events set payload = substr(md5(random()::text) || md5(random()::text), 1, 200)
         where id = v_id and created_at = v_ts;
      end if;
    else
      -- DELETE a recent row (track_changes DELETE), again resolved to the full key for pruning.
      select id, created_at into v_id, v_ts from bench.events
        where user_id = uid and created_at >= v_clock - v_win order by created_at desc limit 1;
      if found then
        delete from bench.events where id = v_id and created_at = v_ts;
      end if;
    end if;
  end loop;
end;
$$;
