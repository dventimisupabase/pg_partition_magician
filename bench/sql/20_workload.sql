-- Server-side workload. One call performs p_ops index-supported operations, so a
-- single client round-trip drives many ops -- the SERVER is the bottleneck, not
-- the network (essential when the driver isn't co-located with the DB). Latency
-- per operation = call latency / p_ops; pg_stat_statements records server-side
-- timing WAN-free. References bench.events by name, so it's identical before and
-- after adoption.
--
-- Every query is the kind you'd actually run against a time-partitioned events
-- table: it filters by user_id (the lookup index) AND a recent created_at window,
-- so post-conversion the planner prunes to the newest partition(s). The cost is
-- therefore ~stable before and after -- which is the point: it lets adopt()/drain
-- degradation show up as the signal instead of being masked by partition fan-out.
-- (A bare "WHERE id = ?" lookup is deliberately avoided: id is not the partition
-- key, so post-conversion it would fan out across every partition and dominate.)
--
-- Mix:
--   40%  head insert (created_at = now())            + companion upsert
--   40%  a user's recent activity, last 7 days, newest 20  (index + pruning)
--   20%  a user's activity count, last 30 days              (index + pruning)
create or replace function bench.workload_step(p_ops int default 50)
returns void language plpgsql as $$
declare
  v_users int;
  r       double precision;
  uid     int;
  newid   bigint;
  i       int;
begin
  -- highest user id (users are a fixed, contiguous 1..N seed). Use max(id), which the planner
  -- answers from the PK index in O(1) -- NOT count(*), which seq-scans all 50k user rows on
  -- every single call (~1 scan/txn => a billion-tuple SEQUENTIAL_SCAN_STORM under load).
  select max(id) into v_users from bench.users;
  for i in 1 .. p_ops loop
    r   := random();
    uid := 1 + floor(random() * v_users)::int;
    if r < 0.40 then
      insert into bench.events (created_at, user_id, kind, payload)
      values (now(), uid, floor(random() * 8)::smallint,
              substr(md5(random()::text) || md5(random()::text) || md5(random()::text), 1, 200))
      returning id into newid;
      insert into bench.user_seen (user_id, last_event, seen_at) values (uid, newid, now())
      on conflict (user_id) do update set last_event = excluded.last_event, seen_at = excluded.seen_at;
    elsif r < 0.80 then
      perform count(*) from (
        select id from bench.events
        where user_id = uid and created_at >= now() - interval '7 days'
        order by created_at desc limit 20
      ) s;
    else
      perform count(*) from bench.events
      where user_id = uid and created_at >= now() - interval '30 days';
    end if;
  end loop;
end;
$$;

-- Write-heavy surge step: insert p_rows wide rows into a throwaway LOGGED sink table in one call.
-- Used by the ambient-surge injection (run.sh BENCH_SURGE_*) to add a clean burst of cluster WAL --
-- a single round-trip emits p_rows of heap+WAL, so a few clients lift the WAL rate enough to exercise
-- adaptive feathering's backoff, without saturating CPU the way the 50-op read/write mix would. It
-- writes to its OWN table (not bench.events): the controller senses cluster-wide WAL regardless of
-- target, so this is a clean stand-in for "a burst of write activity elsewhere in the database" that
-- does not bloat bench.events or perturb the closed tail the drain is moving. (Logged, not unlogged --
-- unlogged tables emit no WAL, which would defeat the purpose.)
create table if not exists bench.surge_sink (id bigint generated always as identity, payload text);
create or replace function bench.surge_step(p_rows int default 500)
returns void language plpgsql as $$
begin
  insert into bench.surge_sink (payload)
  select substr(md5(random()::text) || md5(random()::text) || md5(random()::text), 1, 200)
  from generate_series(1, p_rows);
end;
$$;
