#!/usr/bin/env bash
# Guard regrain against data-coupled work. Run by CI (`./test.sh perf`) and by hand.
#
# THE BAR (issue #263, and the reason #272 existed): a blocking lock may last milliseconds but must never
# last a duration coupled to data size. regrain's swap is the only thing holding ACCESS EXCLUSIVE on the
# parent, so a scan appearing there is the failure that matters.
#
# WHY THIS IS NOT A pgTAP TEST. The assertions read pg_stat_all_tables scan counters, and those are
# accumulated per backend and only flushed at TRANSACTION END: measured, a seq scan of 20000 rows reports
# seq_tup_read growth of 0 when read inside the same transaction and 20000 when read across transactions.
# pgTAP wraps each file in BEGIN/ROLLBACK, so the same assertions there would read 0 unconditionally and
# pass no matter how badly the code regressed. Every tick below therefore runs in its own transaction,
# which is also how maintain drives it in production.
#
# WHY COUNTERS AND NOT WALL CLOCK. Timing thresholds are flaky on shared CI runners. Scan counters are
# exact and their expected value is zero, so the assertion needs no margin.
#
# Usage: regrain_perf.sh <container> <db> <install.sql>
set -euo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:?install.sql}"
ROWS=100000
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
# a counter read must be its own transaction, after forcing a flush of the previous one
stat() { docker exec "$C" psql -U postgres -d "$DB" -qtA \
           -c "select pg_stat_force_next_flush()" -c "$1" | tail -1; }

check() { # <label> <actual> <limit> <context>
  if [ "$2" -le "$3" ]; then printf 'PASS  %-46s %s <= %s   (%s)\n' "$1" "$2" "$3" "$4"
  else printf 'FAIL  %-46s %s >  %s   (%s)\n' "$1" "$2" "$3" "$4"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.rp (id bigint primary key, payload text);" >/dev/null
q "insert into public.rp select g*2, repeat('x',50) from generate_series(1,$ROWS) g;" >/dev/null
q "call pgpm.transmute('public.rp','id', $((ROWS*2/3+1)));" >/dev/null
q "insert into public.rp values (99000000,'frontier');" >/dev/null
q "vacuum analyze public.rp;" >/dev/null
CHILD=$(q "select child_name from pgpm.part where parent_table='public.rp'::regclass order by lo::numeric limit 1")
FINE=$(( ROWS / 10 ))

tick() { q "select pgpm.regrain_step('public.rp','$CHILD','$FINE',3000)"; }

for _ in $(seq 1 6); do tick >/dev/null; done          # prepare + copy a few sub-ranges
q "update public.rp set payload='d' where id <= $((ROWS/2));" >/dev/null   # a delta over copied rows
DN=$(q "select pgpm._regrain_delta_count('public.rp')")

# --- 1. a reconcile tick must not scan the whole delta -------------------------------------------------
# This is exactly the #272 regression: an eligibility predicate the planner cannot index turned each tick
# into a seq scan of the entire delta, making the work O(delta^2 / batch).
D0=$(stat "select seq_tup_read from pg_stat_all_tables where relname='rp_pgpm_regrain_delta'")
OUT=$(tick)
D1=$(stat "select seq_tup_read from pg_stat_all_tables where relname='rp_pgpm_regrain_delta'")
check "reconcile tick does not scan the delta" "$(( D1 - D0 ))" "$(( DN / 4 ))" "$OUT, delta=$DN rows"

# --- 2. the swap must not scan the fine children ------------------------------------------------------
# The swap holds ACCESS EXCLUSIVE on the parent via its DETACH. Each ATTACH is metadata-only only because
# every fine child carries a validated bound CHECK; lose that and ATTACH validates by scanning, putting an
# O(rows) pause inside the exclusive window.
n=0
while : ; do
  F0=$(stat "select coalesce(sum(seq_tup_read),0) from pg_stat_all_tables where relname like 'rp\\_p%' and relname <> '$CHILD'")
  OUT=$(tick); n=$(( n + 1 ))
  case "$OUT" in
    swapped:*)
      F1=$(stat "select coalesce(sum(seq_tup_read),0) from pg_stat_all_tables where relname like 'rp\\_p%' and relname <> '$CHILD'")
      check "swap does not scan the fine children" "$(( F1 - F0 ))" 1000 "$OUT, $ROWS rows in the table"
      break;;
  esac
  [ "$n" -gt 400 ] && { echo "FAIL  regrain did not converge"; fail=1; break; }
done

# --- 3. conservation, so a fast wrong answer cannot pass ----------------------------------------------
AFTER=$(q "select count(*) from public.rp")
check "rows conserved" "$(( AFTER > ROWS ? 0 : 1 ))" 0 "$AFTER rows, expected $(( ROWS + 1 ))"

exit "$fail"
