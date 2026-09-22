#!/usr/bin/env bash
# Guard restore_incoming_fks against blocking the MANAGED PARENT for O(referencing table) (issue #265).
# Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size.
#
# Re-adding a preserve-managed FK is ADD CONSTRAINT ... NOT VALID then VALIDATE, which is the right recipe
# and the standard way to keep a validation scan off a blocking lock. It bought nothing here, because both
# statements shared one transaction: the ADD takes SHARE ROW EXCLUSIVE on BOTH tables and that lock was
# still held while the VALIDATE scanned.
#
# SHARE ROW EXCLUSIVE conflicts with ROW EXCLUSIVE, so this blocked INSERT/UPDATE/DELETE on the referencing
# table AND on the managed parent -- the table pgpm exists to keep online. Measured at 224 ms against 4M
# referencing rows, and linear: roughly 66 ms per million, so a 200M-row referencing table is about 13 s of
# blocked writes on the parent, once per drain campaign, forever.
#
# The assertion is the consequence an operator sees: a plain INSERT into the PARENT, with a lock_timeout
# far shorter than the scan, must never time out while a restore runs. 50 ms against a ~224 ms pre-fix
# hold, so the verdict does not ride on a close call.
#
# WHY THE PROBE DOES NOT WAIT FOR THE RESTORE (issue #416). It used to: a plpgsql loop polled
# pg_stat_activity until it saw `restore_incoming_fks` active, and only then started writing. Measured on
# PG 17.11 against this exact fixture, the FIXED restore runs in 4.4 ms -- it is one ADD CONSTRAINT ...
# NOT VALID, and NOT VALID does not scan. Catching a 4 ms window by polling is not something an instrument
# does reliably, so the probe missed it intermittently, wrote nothing, and reported `at least one write
# landed inside it got false` on correct code. That is the failure this repo's CLAUDE.md warns about
# twice over: an instrument whose cost was never checked against the width of the window it measures, and
# a guard whose green runs therefore meant less than they looked like.
#
# It was worse than intermittent. The old spin loop set its witness AFTER the loop --
#
#     for i in 1 .. 2000000 loop exit when exists(...); commit; end loop;
#     saw := true;
#
# -- so `saw` was true whether the loop found the restore or exhausted two million iterations having seen
# nothing, and the assertion "the probe overlapped a running restore" could not fail. The one witness that
# was supposed to stop "no timeouts" from passing vacuously was itself vacuous.
#
# So the race is gone rather than tuned. A GATE makes the ordering structural: the probe starts writing
# first and announces itself, the restore does not begin until that announcement lands, and the probe does
# not stop until the restore has finished. The probe's write span therefore CONTAINS the restore by
# construction, and nothing has to be caught. What remains is a witness that can actually fail: every
# attempt records the interval it occupied, the restore records the interval it occupied, and the guard
# requires at least one genuine INTERVAL OVERLAP between them. A probe that stalled through the whole
# restore, a gate that did not hold, or a restore too brief for any attempt to touch now all say so.
# Intervals rather than start instants, because an attempt that began before the window and BLOCKED into
# it is the most interesting attempt there is, and a start-timestamp test would drop it.
#
# THAT THE NEW WITNESS CAN FAIL WAS CHECKED, not assumed -- the old one's whole problem was that nobody
# had. Measured on PG 17.11, 200k parent / 4M referencing rows:
#
#   fixed code          4.2-4.4 ms restore, 22-32 of ~800 attempts overlap, 0 timeouts   PASS (5/5 runs)
#   restore_fk_inline_validate (the mutation)
#                       221.8 ms restore,   33 of 852 attempts overlap,     4 timeouts   FAIL, exit 1
#   gate removed, probe stopped before the restore (sabotaged copy, not committed)
#                       9.7 ms restore,     0 of 300 attempts overlap,      0 timeouts   FAIL on the
#                       witness -- and note "writes are not blocked" PASSED there, which is exactly the
#                       vacuous green the old guard reported as success.
#
# Usage: restore_fk_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to prove
# this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
PARENT_ROWS=${PARENT_ROWS:-200000}
REF_ROWS=${REF_ROWS:-4000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.messages (id bigint primary key, body text)" >/dev/null
q "insert into public.messages select g, 'x' from generate_series(1, $PARENT_ROWS) g" >/dev/null
q "create table public.reactions (id bigint primary key,
     message_id bigint not null references public.messages(id), v text)" >/dev/null
q "insert into public.reactions select g, ((g % $PARENT_ROWS) + 1), 'r'
     from generate_series(1, $REF_ROWS) g" >/dev/null
# 'preserve' drops the incoming FK at conversion and records it, so restore_incoming_fks has work to do.
# Everything stays in the monolith and the DEFAULT is empty, so its quiescence gates are already satisfied.
q "call pgpm.transmute('public.messages','id', $PARENT_ROWS::bigint,
     p_incoming_fks => 'preserve', p_paused => false)" >/dev/null
q "vacuum analyze public.messages" >/dev/null
q "vacuum analyze public.reactions" >/dev/null
# wr: one row per write attempt, as the INTERVAL it occupied -- an attempt that started before the restore
# and blocked into it overlaps just as truly as one that started inside, and only intervals see that.
q "create table public.wr (t0 timestamptz, t1 timestamptz, timed_out boolean)" >/dev/null
q "create table public.win (lo timestamptz, hi timestamptz)" >/dev/null
q "create table public.gate (x int)" >/dev/null
q "create table public.done (x int)" >/dev/null

# THE PROBE, started FIRST. COMMIT after every attempt: locks are held to transaction end and a DO block is
# ONE transaction, so a probe that does not commit pins its own ROW EXCLUSIVE on the parent and blocks the
# very ADD it is trying to observe, which makes the run prove nothing. Learned on bench/maintain_lock.sh.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; ok boolean; v_t0 timestamptz;
begin
  -- Announce that the write loop is live. The restore waits for this, so it cannot run before the probe
  -- is writing, and the probe cannot stop before it finishes: the span contains the window by ordering.
  insert into public.gate values (1);
  commit;
  for i in 1 .. 200000 loop
    exit when exists(select 1 from public.done);
    ok := true;
    v_t0 := clock_timestamp();
    begin
      set local lock_timeout = '50ms';
      insert into public.messages (id, body) values ($PARENT_ROWS + n + 1, 'live write');
    exception when others then ok := false;   -- the timeout itself is recorded in wr below
    end;
    n := n + 1;
    insert into public.wr (t0, t1, timed_out) values (v_t0, clock_timestamp(), not ok);
    commit;
  end loop;
end \$p\$;" >/dev/null 2>&1 &
PROBE=$!

# Wait for the probe to be writing. A docker exec poll costs ~100 ms per sample, which is far too coarse to
# time anything -- but this is not timing anything, only establishing that a state has been reached, and it
# is the ordering that the correctness of everything below rests on.
gate=0
for _ in $(seq 1 600); do
  [ "$(q "select count(*) from public.gate")" != "0" ] && { gate=1; break; }
  sleep 0.1
done

# The restore, bracketed by its own interval. Separate -c arguments, so each is its own transaction and the
# restore's lock window is exactly the restore's -- wrapping all three in one would hold its SHARE ROW
# EXCLUSIVE across the bookkeeping too and quietly widen the very thing being measured.
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "insert into public.win (lo) values (clock_timestamp())" \
  -c "select pgpm.restore_incoming_fks('public.messages')" \
  -c "update public.win set hi = clock_timestamp()" \
  -c "insert into public.done values (1)" >/tmp/rfk_bg.log 2>&1
wait $PROBE

OVERLAP=$(q "select count(*) from public.wr, public.win
              where wr.t0 <= win.hi and wr.t1 >= win.lo")
check "LIVENESS: the probe was writing before the restore began" "$gate" "1"
check "LIVENESS: attempts overlapped the restore's own window"  "$([ "${OVERLAP:-0}" -ge 1 ] && echo true || echo false)" "true"
printf '      (%s of %s attempts overlapped a %s ms restore)\n' \
  "${OVERLAP:-0}" "$(q 'select count(*) from public.wr')" \
  "$(q "select round(extract(milliseconds from hi - lo)::numeric, 1) from public.win")"
check "writes to the MANAGED PARENT are not blocked" "$(q "select count(*)::text from public.wr where timed_out")" "0"
# conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets one
# pg_constraint row per partition of the referenced side, so an unfiltered count reports 3 here, not 1.
check "the FK was actually re-added"              "$(q "select count(*)::text from pg_constraint
       where conrelid = 'public.reactions'::regclass and contype = 'f' and conparentid = 0")" "1"

exit "$fail"
