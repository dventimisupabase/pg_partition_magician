#!/usr/bin/env bash
# Guard untransmute's one-way door against a writer racing its check (issue #443). Run by CI
# (`./test.sh perf`).
#
# THE BAR: untransmute must never drop a committed row. It refuses when any row lives outside the
# original monolith ("a metadata-only reverse would lose data"), and before #443 that refusal was
# decided once, under ACCESS SHARE, by a `select exists` that cannot see another session's uncommitted
# insert. The DETACH and DROP that act on its answer took their ACCESS EXCLUSIVE later. So a writer
# whose insert into a forward partition was uncommitted at the check, and committed before that lock
# was granted, had its row dropped with the parent, and pgpm.log recorded `untransmute` as a success.
# The fix takes the lock explicitly, one statement before the DETACH would have, and asks the question
# again under it.
#
# WHAT THIS DRIVES. Three sessions, in the order the race needs, with no timing guesses:
#
#   the WRITER   begins, inserts one row (id 7777) into a forward partition, and then parks in a
#                server-side loop polling a gate table, so the insert stays UNCOMMITTED for exactly as
#                long as this guard wants and not a millisecond longer than it takes to release it.
#   untransmute  runs in a second session once the writer's lock is visible. It passes its unlocked
#                check (the row is invisible to it) and blocks on ACCESS EXCLUSIVE, behind the writer's
#                ROW EXCLUSIVE.
#   this script  polls pg_locks from a third session until it sees untransmute WAITING, records the
#                writer's state at that instant, then opens the gate. The writer commits, untransmute
#                gets its lock, and what it does next is the property under test.
#
# THE LIVENESS WITNESS, and why the verdict is worthless without it. "The row was not lost" is a
# negative, and a negative is equally satisfied by a run where the race never happened: a writer that
# committed before untransmute ever looked (then the FIRST check refuses, exactly as tests/27 shows it
# does, and the fix is not exercised), a writer that failed to connect, an untransmute that hit an
# unrelated error before reaching the lock. So the guard asserts, from the third session and BEFORE
# releasing the writer, that untransmute is already waiting for AccessExclusiveLock on the parent
# (granted = false) while the writer still holds an open xid and a granted RowExclusiveLock on it. The
# wait proves the unlocked check has already run and passed; the open xid proves the row it missed is
# still uncommitted. If either witness fails the guard fails, rather than reporting a clean bill of
# health for a race that was never in place.
#
# THE INSTRUMENT'S COST AGAINST THE WINDOW'S WIDTH. A `docker exec ... psql` sample costs 40-80 ms on
# this machine, which would be useless against a window that lasts 4 ms (bench/restore_fk_lock.sh's
# lesson). It is adequate here because the window is not a duration at all: untransmute stays parked
# on its lock wait until THIS script opens the gate, so the state persists for as long as the poll
# takes to notice it, and nothing about the verdict depends on how long that was. The sampling
# sessions never touch public.ur while untransmute waits: a new ACCESS SHARE request queues behind a
# PENDING ACCESS EXCLUSIVE, so a sample that read the table would deadlock the guard against the very
# wait it is trying to witness. Every witness reads pg_locks and pg_stat_activity only.
#
# THE OTHER DIRECTION. A fix that made untransmute refuse unconditionally would pass every assertion
# above, so a second table with no concurrent writer must still untransmute cleanly.
#
# Measured on PG 17.11 against this exact fixture, 2026-09-24:
#
#   pre-#443 install.sql, and the mutation untransmute_no_recheck_under_lock (identical results)
#                all three witnesses PASS, then untransmute returns normally with exit 0, no row
#                answers to id 7777 through public.ur, public.ur is relkind r, pgpm.config has no
#                row for it and pgpm.log carries an `untransmute` success row: 7 checks FAIL,
#                while the uncontended ur_clean direction still passes, so the failure is the
#                defect's and not the fixture's                                    FAIL, exit 1
#   fixed        all three witnesses PASS, untransmute exits non-zero with the one-way-door message,
#                row 7777 reads back as 'late' from ur_p2026_10 through public.ur, and ur_clean
#                reverses cleanly                                                  PASS, 20 of 20
#
# Usage: untransmute_race.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
qraw() { docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# A previous run's backgrounded sessions can outlive their script and keep DROP DATABASE from
# succeeding, and a swallowed DROP error means silently running against a stale database
# (bench/regrain_swap_timing.sh learned this the hard way).
docker exec "$C" psql -U postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "drop database if exists $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not drop database $DB (stale connection?)"; exit 1; }
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not create database $DB"; exit 1; }
docker exec "$C" psql -U postgres -d "$DB" -qv ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null 2>&1 \
  || { echo "FAIL  could not install $INSTALL"; exit 1; }
# A witness that the install landed, anchored on the function this guard calls: a mutant that will not
# load would otherwise produce a wall of confusing failures instead of naming the cause.
check "pgpm installed into $DB, with untransmute defined" \
  "$(q "select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'pgpm' and p.proname = 'untransmute'")" "1"

# ---- the fixture: a transmuted table with empty forward partitions, the state untransmute reverses ----
# 100 rows over the last 100 minutes, so the monolith is this month and every forward partition obtain
# builds is empty. The late row goes to the FIRST forward partition, one hour past the monolith's hi.
qraw "create table public.ur (
        id bigint generated by default as identity,
        created_at timestamptz not null default now(),
        body text,
        primary key (created_at, id));
      insert into public.ur (created_at, body)
        select now() - (g || ' minutes')::interval, 'b' || g from generate_series(1, 100) g;" >/dev/null \
  || { echo "FAIL  fixture: could not create public.ur"; exit 1; }
qraw "call pgpm.transmute('public.ur', 'created_at', interval '1 month')" >/dev/null \
  || { echo "FAIL  fixture: transmute failed"; exit 1; }
qraw "select pgpm.obtain('public.ur')" >/dev/null \
  || { echo "FAIL  fixture: obtain failed"; exit 1; }

MON=$(q "select child_name from pgpm.part where parent_table = 'public.ur'::regclass and attached
          order by lo::timestamptz limit 1")
MON_HI=$(q "select hi from pgpm.part where parent_table = 'public.ur'::regclass and attached
             order by lo::timestamptz limit 1")
LATE_TS=$(q "select ('$MON_HI'::timestamptz + interval '1 hour')::text")
FWD=$(q "select child_name from pgpm.part where parent_table = 'public.ur'::regclass and attached
          and lo::timestamptz <= '$LATE_TS'::timestamptz and hi::timestamptz > '$LATE_TS'::timestamptz")
check "fixture: the monolith is the attached partition with the smallest lo" \
  "$([ -n "$MON" ] && echo present || echo missing)" "present"
check "fixture: a forward partition, not the monolith, covers the late row" \
  "$([ -n "$FWD" ] && [ "$FWD" != "$MON" ] && echo true || echo false)" "true"

# The gate the writer parks on, and the server-side wait it parks in. A plpgsql loop rather than
# pg_sleep(N): the insert stays uncommitted until the gate opens, not for a guessed interval that is
# either too short (the writer commits before untransmute looks, and the FIRST check refuses) or a
# fixed cost on every run. READ COMMITTED gives each iteration's `exists` a fresh snapshot, so it sees
# this script's committed gate row from inside the writer's still-open transaction.
q "create table public.ur_gate (x int)" >/dev/null
# shellcheck disable=SC2016  # single quotes are the point: $f$ is a dollar-quote, not a shell variable
q 'create function public.ur_gate_wait() returns void language plpgsql as $f$
   begin
     for i in 1 .. 1200 loop
       exit when exists (select 1 from public.ur_gate);
       perform pg_sleep(0.05);
     end loop;
   end $f$' >/dev/null

# ---- the WRITER: one uncommitted row in a forward partition, held until released ----
# Separate -c flags on purpose: psql sends each on its own, and the explicit BEGIN/COMMIT make them
# one transaction, so the insert is uncommitted for exactly the span of the gate wait.
WLOG=$(mktemp); ALOG=$(mktemp)
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'ur443_writer'" \
  -c "begin" \
  -c "insert into public.ur (id, created_at, body) values (7777, '$LATE_TS', 'late')" \
  -c "select public.ur_gate_wait()" \
  -c "commit" >"$WLOG" 2>&1 &
WRITER=$!
A=""
trap 'kill $WRITER $A 2>/dev/null; rm -f "$WLOG" "$ALOG"' EXIT

# Wait for the writer's insert to be in flight, rather than sleeping a guessed interval and hoping.
w_holds=0
for _ in $(seq 1 100); do
  w_holds=$(q "select count(*)::int from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.datname = current_database() and a.application_name = 'ur443_writer'
                  and l.locktype = 'relation' and l.relation = 'public.ur'::regclass
                  and l.mode = 'RowExclusiveLock' and l.granted")
  [ "${w_holds:-0}" = "1" ] && break
  sleep 0.1
done
check "the writer holds ROW EXCLUSIVE on the parent (its insert is in flight)" "${w_holds:-0}" "1"

# ---- untransmute, in a session of its own, against a table whose late row it cannot yet see ----
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'ur443_untransmute'" \
  -c "select pgpm.untransmute('public.ur')" >"$ALOG" 2>&1 &
A=$!

# Poll until untransmute is WAITING for the parent's ACCESS EXCLUSIVE, and read the writer's state in
# the same statement, so the three witnesses describe one instant. Nothing here reads public.ur.
a_waiting=0; w_open=0; w_locked=0
for _ in $(seq 1 300); do
  IFS='|' read -r a_waiting w_open w_locked < <(q "
    select
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.datname = current_database() and a.application_name = 'ur443_untransmute'
          and a.query like '%pgpm.untransmute%'
          and l.locktype = 'relation' and l.relation = 'public.ur'::regclass
          and l.mode = 'AccessExclusiveLock' and not l.granted),
      (select count(*) from pg_stat_activity a
        where a.datname = current_database() and a.application_name = 'ur443_writer'
          and a.backend_xid is not null),
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.datname = current_database() and a.application_name = 'ur443_writer'
          and l.locktype = 'relation' and l.relation = 'public.ur'::regclass
          and l.mode = 'RowExclusiveLock' and l.granted)")
  [ "${a_waiting:-0}" = "1" ] && break
  sleep 0.1
done

# ---- the liveness witnesses: the race is real, and it is the race this guard is about ----
check "LIVENESS: untransmute passed its first check and is waiting for ACCESS EXCLUSIVE" "${a_waiting:-0}" "1"
check "LIVENESS: while the writer's insert is still uncommitted (open xid)" "${w_open:-0}" "1"
check "LIVENESS: and the writer still holds ROW EXCLUSIVE on the parent" "${w_locked:-0}" "1"

# ---- open the gate: the writer commits, untransmute gets its lock ----
q "insert into public.ur_gate values (1)" >/dev/null
wait "$WRITER"; W_RC=$?
wait "$A"; A_RC=$?
A=""
check "the writer's commit went through" "$W_RC" "0"

# ---- the property under test ----
check "untransmute refused (non-zero exit)" \
  "$([ "$A_RC" -ne 0 ] && echo refused || echo "returned normally")" "refused"
check "with the one-way-door message" \
  "$(grep -q 'rows now live outside the original monolith' "$ALOG" && echo true || echo false)" "true"
check "row 7777 is still reachable through public.ur" \
  "$(q "select body from public.ur where id = 7777")" "late"
check "in the forward partition it was written to" \
  "$(q "select relname from pg_class where oid = (select tableoid from public.ur where id = 7777)")" "$FWD"
check "rows 1..100 are all still there, by identity" \
  "$(q "select (select string_agg(id::text, ',' order by id) from public.ur where id <> 7777)
             = (select string_agg(g::text, ',' order by g) from generate_series(1, 100) g)")" "t"
check "public.ur is still the partitioned parent (the refusal rolled everything back)" \
  "$(q "select relkind::text from pg_class where oid = 'public.ur'::regclass")" "p"
check "pgpm still manages it" \
  "$(q "select count(*)::int from pgpm.config where parent_table = 'public.ur'::regclass")" "1"
check "pgpm.log carries no untransmute success row for it" \
  "$(q "select count(*)::int from pgpm.log
         where parent_table = 'public.ur'::regclass and action = 'untransmute'")" "0"
if [ "$A_RC" -eq 0 ]; then
  printf '      untransmute output: %s\n' "$(tr '\n' ' ' <"$ALOG")"
fi

# ---- the other direction: with no writer in the window, the reverse must still go through ----
qraw "create table public.ur_clean (
        id bigint generated by default as identity,
        created_at timestamptz not null default now(),
        body text,
        primary key (created_at, id));
      insert into public.ur_clean (created_at, body)
        select now() - (g || ' minutes')::interval, 'c' || g from generate_series(1, 100) g;" >/dev/null
qraw "call pgpm.transmute('public.ur_clean', 'created_at', interval '1 month')" >/dev/null
qraw "select pgpm.obtain('public.ur_clean')" >/dev/null
# The bare call, not `select relname from pg_class where oid = pgpm.untransmute(...)`: a volatile function
# in a WHERE clause runs once per pg_class row, and the second call fails with "not managed by pgpm".
check "an uncontended untransmute still returns the table" \
  "$(q "select pgpm.untransmute('public.ur_clean')::text" 2>/dev/null)" "ur_clean"
check "and it is an ordinary table again" \
  "$(q "select relkind::text from pg_class where oid = 'public.ur_clean'::regclass")" "r"
check "holding exactly rows 1..100" \
  "$(q "select (select string_agg(id::text, ',' order by id) from public.ur_clean)
             = (select string_agg(g::text, ',' order by g) from generate_series(1, 100) g)")" "t"
check "with its untransmute logged" \
  "$(q "select count(*)::int from pgpm.log
         where parent_table = 'public.ur_clean'::regclass and action = 'untransmute'")" "1"

[ "$fail" = 0 ] && echo "untransmute_race: PASS" || echo "untransmute_race: FAIL"
exit "$fail"
