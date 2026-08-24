#!/usr/bin/env bash
# Guard the uuidv7 forward frontier against a data drought (issue #325). Run by CI (`./test.sh perf`,
# and `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT. Every control kind's forward frontier is either the clock (`time`) or bounded by it
# (`id` has no clock, so it cannot fall behind where the next write goes). `uuidv7` is a time grid fed
# by DATA: pre-#325, its frontier was plain `max(control)`, decoded. A table whose writes go quiet -- a
# restored dump, a stale clone, a table that just stops getting writes for `obtain x step` -- has that
# frontier stuck wherever the data ended while now() keeps moving. obtain then measures itself against
# its own past output, finds nothing to do, and the grid stalls exactly where the drought began. Every
# write past it is refused with a bare `no partition of relation ... found for row`, permanently, and
# nothing in the log distinguishes this tick from a healthy one.
#
# WHY A SHELL HARNESS, GIVEN tests/85_uuidv7_frontier_drought_test.sql ALREADY PROVES THE LOGIC. It
# does, inside one pgTAP transaction. What that cannot show is the property the issue itself measured:
# that the fix holds up across SEPARATE maintenance ticks over real (if small) elapsed wall-clock time,
# not just one evaluation of now(). It also is not wired into bench/discriminate.sh's mutation-proof
# machinery -- CLAUDE.md's rule that a guard this easy to write vacuously is worthless without a kept,
# standing proof it discriminates applies here regardless of which harness the guard lives in, and the
# mutation apparatus only drives guards under bench/.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   1. LIVENESS WITNESS: the backfilled data really is stale enough to wedge under the pre-#325 rule
#      (> obtain x step behind now()). Every assertion below reads as "obtain still reaches now()",
#      which would also pass vacuously against a fixture that was never actually stale.
#   2. + 3. per tick, across THREE SEPARATE `pgpm.maintain()` calls (three separate sessions, three
#      separate now()s, matching the issue's own "across five ticks" table): a partition covers now()
#      BY IDENTITY (its own [lo, hi), not "some partition exists somewhere"), and a uuidv7 row stamped
#      at now() is accepted rather than refused. Checked every tick, not once, because the pre-#325
#      defect's defining symptom was that nothing changes tick over tick -- a guard that only checked
#      tick 1 could not tell "fixed" apart from "coincidentally not wedged yet".
#
# Usage: frontier_drought.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q()   { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f "$INSTALL" >/tmp/fd_install.log 2>&1; then
  echo "FAIL  install did not complete"; sed 's/^/      /' /tmp/fd_install.log; exit 1
fi

# The fixture: two rows backfilled 13 and 11 months stale, matching the issue's own reproduction. A
# monthly step with p_obtain => 2 gives 2 months of lookahead -- nowhere near enough to reach "now" from
# an 11-month-old frontier by luck, so this cannot pass by accident of a generous default.
run "create table public.fd (id uuid primary key, body text)" >/dev/null
run "insert into public.fd (id, body) values
       (pgpm._ts_to_uuid(now() - interval '13 months'), 'oldest'),
       (pgpm._ts_to_uuid(now() - interval '11 months'), 'newest')" >/dev/null

GAP=$(q "select (now() - (select pgpm._uuid_to_ts(id) from public.fd order by id desc limit 1)) > interval '2 months'")
check "the backfilled frontier is well outside the 2-month lookahead" "$GAP" "t"

run "call pgpm.transmute('public.fd', 'id', interval '1 month', p_obtain => 2)" >/dev/null
run "select pgpm.resume('public.fd')" >/dev/null

for tick in 1 2 3; do
  run "call pgpm.maintain('public.fd')" >/dev/null

  COVERS=$(q "select exists (
                select 1 from pgpm.part
                 where parent_table = 'public.fd'::regclass and attached
                   and lo::timestamptz <= now() and hi::timestamptz > now())")
  check "tick $tick: a partition covers now()" "$COVERS" "t"

  if run "insert into public.fd (id, body) values (pgpm._ts_to_uuid(now()), 'tick-$tick')" \
       >/tmp/fd_insert.log 2>&1; then
    check "tick $tick: a write at now() is accepted" "accepted" "accepted"
  else
    check "tick $tick: a write at now() is accepted" "rejected: $(tail -1 /tmp/fd_insert.log | cut -c1-70)" "accepted"
  fi
done

exit "$fail"
