#!/usr/bin/env bash
# Guard obtain's back-off against outlasting the forward grid, and against ignoring grid it cannot see.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches both defects).
#
# THE DEFECT. maintain_obtain() runs obtain under a 200 ms lock_timeout, and a lost race sets
# config.obtain_retry_after 30 s out so sustained write contention does not queue an ACCESS EXCLUSIVE on
# the parent every tick. The back-off predates #288, when a DEFAULT partition caught any write past the
# grid. Since #288 such a write is refused, and a fixed back-off can outlast the lookahead: a local load
# test (~42k ids/s against obtain 3 x step 200000, ~14 s of grid) lost one race, backed off 30 s, and every
# client aborted with `no partition of relation ... found for row`. The fix honors the back-off only while
# at least ceil(obtain / 2) complete grid steps of attached coverage remain beyond the frontier's own cell.
#
# THE OVER-CORRECTION. Headroom is COVERAGE, not a count of partitions that start past the frontier.
# transmute's p_bound_headroom gives the monolith a permanent hi several steps beyond the frontier; that room
# is real, but the monolith's lo is far behind the frontier, so a count of "partitions starting ahead" sees
# none of it and bypasses the back-off every tick, retrying the very ACCESS EXCLUSIVE the back-off exists to
# spare a contended table (reported in review on #386 and reproduced).
#
# WHY A SHELL HARNESS, GIVEN tests/100 ALREADY PROVES THE DECISION. tests/100 sets obtain_retry_after by hand.
# Only a second session holding a real lock can show the path that actually produced the outage: a genuine
# lock-timeout deferral, logged and backed off, followed by a tick whose decision is then under test.
#
# WHAT IT ASSERTS, and why each is load-bearing (step 1000, obtain 4):
#   public.ob_race (monolith [0,1000), grid top 5000):
#   1. + 2. LIVENESS WITNESS: the race really happened -- a skip_obtain row carrying the lock-timeout error,
#      and a back-off set in the future. Without these, every assertion below could pass against a tick
#      that never contended for anything.
#   3. The back-off still holds while headroom is ample (frontier in [2000,3000), 2 steps covered beyond it):
#      the next tick creates nothing even though obtain has partitions to create. A "fix" that deletes the
#      back-off fails here.
#   4. The back-off is still in the future immediately before the low-headroom tick, so assertion 5 cannot
#      pass merely because 30 s elapsed.
#   5. + 6. With headroom low (frontier in [4000,5000), 0 steps beyond) the tick extends the grid anyway, by
#      identity (the partition count), and a write at 8999 is accepted rather than refused.
#   public.ob_hr (p_bound_headroom => 4: the monolith [0,5000) is the only partition):
#   7. + 8. LIVENESS WITNESS again, for this table's own race.
#   9. Frontier in [1000,2000) leaves 3 steps covered INSIDE the monolith: the back-off holds and nothing is
#      created, although obtain has [5000,6000) to create. Counting only partitions that start past the
#      frontier fails here.
#   public.ob_q (obtain 3, where ceil(3/2)=2 but integer 3/2=1):
#   10. + 11. LIVENESS WITNESS again, for this table's own race.
#   12. With exactly 1 complete step of headroom the tick must still extend the grid: 1 < ceil(3/2). Integer
#       division makes the threshold 1, so the back-off would be honored and nothing created. obtain 4 (above)
#       cannot see that difference, since ceil(4/2) and 4/2 are both 2.
#
# Usage: obtain_backoff_headroom.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q()   { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-66s %s\n' "$1" "$2"
  else printf 'FAIL  %-66s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
parts() { q "select count(*) from pgpm.part where parent_table = '$1'::regclass and attached"; }

# Run one maintain_obtain tick while a second session holds ACCESS SHARE on the parent (which conflicts with
# obtain's ACCESS EXCLUSIVE), so the tick loses a genuine lock race. Then assert the race's liveness witness.
raced_tick() { # <table> <label prefix>
  local rel="${1#public.}" holder held
  docker exec "$C" psql -U postgres -d "$DB" -qtA \
    -c "begin; lock table $1 in access share mode; select pg_sleep(4); commit;" >/dev/null 2>&1 &
  holder=$!
  for _ in $(seq 1 50); do
    held=$(q "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
               where c.relname = '$rel' and l.mode = 'AccessShareLock' and l.granted and l.pid <> pg_backend_pid()")
    [ "$held" -gt 0 ] 2>/dev/null && break
    sleep 0.1
  done
  run "call pgpm.maintain_obtain('$1')" >/dev/null
  wait "$holder"
  check "$2: the lock race really happened: skip_obtain with a lock timeout" \
    "$(q "select exists (select 1 from pgpm.log where parent_table = '$1'::regclass
                          and action = 'skip_obtain' and method like '%lock timeout%')")" "t"
  check "$2: the deferral set a back-off in the future" \
    "$(q "select obtain_retry_after > clock_timestamp() from pgpm.config where parent_table = '$1'::regclass")" "t"
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f "$INSTALL" >/tmp/obh_install.log 2>&1; then
  echo "FAIL  install did not complete"; sed 's/^/      /' /tmp/obh_install.log; exit 1
fi

# ------------------------------------------------------------------ public.ob_race: forward grid headroom
run "create table public.ob_race (id bigint generated by default as identity primary key, body text)" >/dev/null
run "insert into public.ob_race (body) select 'x' from generate_series(1, 500)" >/dev/null
run "call pgpm.transmute('public.ob_race', 'id', 1000::bigint, 4, p_paused => false)" >/dev/null
# Frontier into [2000,3000): obtain now has partitions to create, so it must take the parent's lock.
run "insert into public.ob_race (id, body) values (2001, 'frontier')" >/dev/null
raced_tick public.ob_race "ob_race"

# Lock released, 2 steps still covered beyond the frontier's cell: the back-off must hold.
run "call pgpm.maintain_obtain('public.ob_race')" >/dev/null
check "ob_race: ample headroom: the back-off holds, nothing created" "$(parts public.ob_race)" "5"

# Frontier into [4000,5000): nothing covered beyond it.
run "insert into public.ob_race (id, body) values (4001, 'frontier')" >/dev/null
check "ob_race: the back-off is still in the future before the low-headroom tick" \
  "$(q "select obtain_retry_after > clock_timestamp() from pgpm.config where parent_table = 'public.ob_race'::regclass")" "t"

run "call pgpm.maintain_obtain('public.ob_race')" >/dev/null
check "ob_race: low headroom: the tick extends the grid through the back-off" "$(parts public.ob_race)" "9"
if run "insert into public.ob_race (id, body) values (8999, 'past the old top')" >/tmp/obh_insert.log 2>&1; then
  check "ob_race: a write at 8999, past the old grid top of 5000, is accepted" "accepted" "accepted"
else
  check "ob_race: a write at 8999, past the old grid top of 5000, is accepted" "rejected: $(tail -1 /tmp/obh_insert.log | cut -c1-60)" "accepted"
fi

# ------------------------------------------------------------------ public.ob_hr: headroom inside the monolith
run "create table public.ob_hr (id bigint generated by default as identity primary key, body text)" >/dev/null
run "insert into public.ob_hr (body) select 'x' from generate_series(1, 500)" >/dev/null
run "call pgpm.transmute('public.ob_hr', 'id', 1000::bigint, 4, p_paused => false, p_bound_headroom => 4)" >/dev/null
# Frontier into [1000,2000): 3 complete steps covered inside the monolith [0,5000), and obtain has
# [5000,6000) to create, so the tick must take the parent's lock.
run "insert into public.ob_hr (id, body) values (1001, 'frontier')" >/dev/null
raced_tick public.ob_hr "ob_hr"

run "call pgpm.maintain_obtain('public.ob_hr')" >/dev/null
check "ob_hr: 3 steps covered inside the monolith: the back-off holds" "$(parts public.ob_hr)" "1"

# ------------------------------------------------------------------ public.ob_q: ceil, not integer division
# obtain 3: monolith [0,1000) plus forward [1000,2000), [2000,3000), [3000,4000) -> grid top 4000.
run "create table public.ob_q (id bigint generated by default as identity primary key, body text)" >/dev/null
run "insert into public.ob_q (body) select 'x' from generate_series(1, 500)" >/dev/null
run "call pgpm.transmute('public.ob_q', 'id', 1000::bigint, 3, p_paused => false)" >/dev/null
# Frontier into [2000,3000) leaves exactly one complete step covered beyond it, and gives obtain work to do,
# so the raced tick below contends for the parent's lock.
run "insert into public.ob_q (id, body) values (2001, 'frontier')" >/dev/null
raced_tick public.ob_q "ob_q"

run "call pgpm.maintain_obtain('public.ob_q')" >/dev/null
check "ob_q: 1 step of headroom with obtain 3 (< ceil(3/2)): the tick extends the grid" "$(parts public.ob_q)" "6"

exit "$fail"
