#!/usr/bin/env bash
# Guard obtain against holding a data-coupled lock while it builds a partition (issue #280).
# Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last
# a duration coupled to data size.
#
# To create a partition beside a non-empty DEFAULT, someone has to prove the DEFAULT holds no row in the
# new range. pgpm does that with ADD CONSTRAINT ... NOT VALID then VALIDATE, so the subsequent CREATE can
# skip its own scan. Before #280 all four statements shared one transaction, so the ADD's ACCESS
# EXCLUSIVE was still held over the VALIDATE's O(rows) scan and the DEFAULT -- where the live workload
# writes -- was locked for the whole of it. Measured at 157 ms against a 947 MB DEFAULT, and unbounded:
# a larger or colder DEFAULT makes it seconds.
#
# Split across transactions the scan runs under SHARE UPDATE EXCLUSIVE, which does not conflict with
# ROW EXCLUSIVE, so writes proceed. Two assertions, because they fail differently:
#
#   1. the lock MODE during the scan. Margin-free: either ACCESS EXCLUSIVE is held or it is not.
#   2. a concurrent INSERT routing into the DEFAULT. This is the consequence an operator sees, and it
#      catches a regression that keeps the mode nominally right but blocks writes some other way.
#
# The reader's lock_timeout is 50 ms against a ~157 ms pre-fix hold and a ~1 ms post-fix one, so
# neither verdict rides on a close call.
#
# Usage: obtain_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
MONO=${MONO:-4000000}       # rows loaded before the conversion; the monolith covers them
TAIL=${TAIL:-4000000}       # rows written past the monolith, which land in the DEFAULT
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.ob (id bigint primary key, v text)" >/dev/null
q "insert into public.ob select g, repeat('x',200) from generate_series(1,$MONO) g" >/dev/null
q "call pgpm.transmute('public.ob','id', $MONO::bigint, p_paused => false)" >/dev/null
# Rows PAST the monolith land in the DEFAULT and are what makes obtain take the constraint path at all:
# on an EMPTY default it uses a single plain CREATE and none of this applies. The monolith's upper bound
# is read back rather than assumed, since transmute rounds it up to the next grid step.
HI=$(q "select max(hi::bigint) from pgpm.part where parent_table='public.ob'::regclass")
q "insert into public.ob select g, repeat('x',200) from generate_series($((HI+1)), $((HI+TAIL))) g" >/dev/null
q "vacuum analyze public.ob" >/dev/null
q "create table public.probe (caught boolean, modes text, wr text)" >/dev/null

docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "call pgpm.obtain('public.ob')" >/tmp/ob_bg.log 2>&1 &
BG=$!

# Poll SERVER-SIDE. Sampling through repeated `docker exec` costs ~100 ms per sample, which is longer
# than the window being measured, so a probe built that way can never land inside it and every
# assertion passes vacuously. Learned on bench/transmute_lock.sh.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare m text; got boolean := false; w text := 'not attempted';
begin
  for i in 1 .. 2000000 loop
    select coalesce(string_agg(distinct l.mode, ',' order by l.mode), '(none)') into m
      from pg_locks l join pg_class c on c.oid = l.relation
     where c.relname = 'ob_default' and l.pid <> pg_backend_pid() and l.granted;
    if m like '%ShareUpdateExclusiveLock%' then got := true; exit; end if;
  end loop;
  if got then
    begin
      set local lock_timeout = '50ms';
      insert into public.ob (id, v) values ($((HI + TAIL + 1)), 'written during the scan');
      w := 'accepted';
    exception when others then w := sqlstate; end;
  end if;
  insert into public.probe values (got, m, w);
end \$p\$;" >/dev/null 2>&1
wait $BG

CAUGHT=$(q "select caught::text from public.probe limit 1")
MODES=$(q  "select modes        from public.probe limit 1")
WR=$(q     "select wr           from public.probe limit 1")

# Positive evidence first: without it, a probe that missed the window entirely reports no locks and
# sails through the mode assertion having tested nothing.
check "the probe caught the validation scan in progress" "$CAUGHT" "true"
case "$MODES" in
  *AccessExclusiveLock*) check "ACCESS EXCLUSIVE is not held during the scan" "held: $MODES" "not held" ;;
  *)                     check "ACCESS EXCLUSIVE is not held during the scan" "not held" "not held" ;;
esac
check "a concurrent writer to the DEFAULT is not blocked" "$WR" "accepted"
check "obtain built the partition"  "$(q "select (count(*) > 0)::text from pgpm.log
       where parent_table='public.ob'::regclass and action = 'obtain' and method = 'check_skip'")" "true"
check "and left no constraint behind" "$(q "select count(*) from pg_constraint
       where conrelid='public.ob_default'::regclass and conname = 'pgpm_obtain_excl'")" "0"

exit "$fail"
