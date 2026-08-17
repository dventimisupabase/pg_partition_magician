#!/usr/bin/env bash
# Guard retirement of a REFERENCED partition against blocking the MANAGED PARENT (issue #268).
# Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last
# a duration coupled to data size.
#
# Retiring a partition that an incoming foreign key references cannot be a bare DROP: PostgreSQL
# refuses that on a pure catalog dependency, which is the wedge #268 is about. It has to DETACH first.
# The tempting way to write that is a plain `ALTER TABLE ... DETACH PARTITION` from inside retire(),
# and it is wrong for a reason no functional test would catch, because the outcome is identical:
#
#   ALTER TABLE ... DETACH PARTITION               AccessExclusiveLock on the MANAGED PARENT, ~1.5 s
#                                                  at 8M referencing rows; a concurrent read of the
#                                                  parent dies with 55P03
#   ALTER TABLE ... DETACH PARTITION CONCURRENTLY  ShareUpdateExclusiveLock; reads and writes proceed
#
# The duration is set by the size of the REFERENCING table -- a table pgpm does not own and did not
# choose -- because the detach must scan it to prove no row still references the partition. So the
# blocking form makes retention stall the very table pgpm exists to keep online, for as long as
# somebody else's table is big. Measured: 159 ms against 2M referencing rows, 420 ms against 8M, and
# 343 ms even when the partition being detached holds only 10 rows.
#
# PostgreSQL refuses to run the concurrent form from a function, a procedure or a DO block, so pgpm
# cannot issue it at all: it dispatches it to pg_cron, which runs it as a top-level statement in its
# own session. tests/78 owns that handoff (does pgpm ask cron for the right statement?). THIS guard
# owns the consequence an operator feels, and deliberately does not involve cron: the background
# session below runs the detach at the top level exactly as the cron worker would, and the probe
# asserts the parent stayed usable while it did.
#
# The assertion is what a live application sees: plain SELECTs and INSERTs on the PARENT, with a
# lock_timeout far shorter than the scan, must never time out. 50 ms against a ~500 ms pre-fix hold, so
# neither verdict rides on a close call.
#
# Usage: retire_detach_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
PARENT_ROWS=${PARENT_ROWS:-200000}
# Sized so the window is wide relative to the instrument, not merely non-zero. The probe's unit of
# observation costs one lock_timeout (50 ms), so a defect that blocks for only ~100 ms would register
# as one or two timeouts and the verdict would ride on scheduling noise. At 8M referencing rows the
# blocking form holds its ACCESS EXCLUSIVE for ~500 ms, which is ~10 observations wide.
REF_ROWS=${REF_ROWS:-8000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-56s %s\n' "$1" "$2"
  else printf 'FAIL  %-56s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

# The managed parent: monolith [0, 250000), horizon 400000 after the frontier write, so the monolith is
# entirely past it and eligible for retirement.
q "create table public.messages (id bigint primary key, body text)" >/dev/null
q "insert into public.messages select g, 'x' from generate_series(1, $PARENT_ROWS) g" >/dev/null
q "call pgpm.transmute('public.messages','id', 50000::bigint, p_retain => 100000::bigint, p_paused => false)" >/dev/null
q "select pgpm.obtain('public.messages')" >/dev/null
q "insert into public.messages values (500000, 'frontier')" >/dev/null

# The referencing table, and the reason the detach is expensive. Every row points at the FRONTIER row,
# NOT into the doomed partition: this guard is about the lock, so there must be no crossing to resolve.
q "create table public.reactions (id bigint primary key,
     message_id bigint not null references public.messages(id), v text)" >/dev/null
q "insert into public.reactions select g, 500000, 'r' from generate_series(1, $REF_ROWS) g" >/dev/null
q "vacuum analyze public.messages" >/dev/null
q "vacuum analyze public.reactions" >/dev/null
q "create table public.probe (writes int, reads int, timeouts int, saw boolean)" >/dev/null
q "create table public.done (x int)" >/dev/null

CHILD=$(q "select child_name from pgpm.part where parent_table = 'public.messages'::regclass and lo = '0'")
SCANS_BEFORE=$(q "select seq_scan from pg_stat_all_tables where relid = 'public.reactions'::regclass")

# The retirement, in the shape production runs it: retire() decides and dispatches, then the detach
# happens as a TOP-LEVEL statement in a separate session -- which is the only context PostgreSQL
# permits the concurrent form in, and exactly what the cron worker does. Against a mutant that detaches
# in-process, retire() itself takes the blocking lock and the second statement simply finds nothing
# left to detach (no ON_ERROR_STOP, so the run continues to signal `done` either way).
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "select pgpm.retire('public.messages', '$CHILD')" \
  -c "alter table public.messages detach partition public.$CHILD concurrently" \
  -c "insert into public.done values (1)" >/tmp/retire_detach_bg.log 2>&1 &
BG=$!

# COMMIT after every observation. Locks are held to transaction end and a DO block is ONE transaction,
# so a probe that just loops pins its own AccessShare on the parent and blocks the very DETACH it is
# trying to observe, which would make the run prove nothing. Learned on bench/maintain_lock.sh.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; rd int := 0; t int := 0; found boolean := false;
begin
  for i in 1 .. 2000000 loop
    if exists(select 1 from pg_stat_activity
               where datname = current_database() and pid <> pg_backend_pid() and state = 'active'
                 and (query ilike '%detach partition%' or query ilike '%pgpm.retire%')) then
      found := true; exit;
    end if;
    commit;
  end loop;
  while not exists(select 1 from public.done) loop
    begin
      set local lock_timeout = '50ms';
      perform count(*) from public.messages where id = 1;
      rd := rd + 1;
    exception when others then t := t + 1; end;
    begin
      set local lock_timeout = '50ms';
      insert into public.messages (id, body) values (600000 + n, 'live write');
      n := n + 1;
    exception when others then t := t + 1; end;
    commit;
  end loop;
  insert into public.probe values (n, rd, t, found);
end \$p\$;" >/dev/null 2>&1
wait $BG

SCANS_AFTER=$(q "select seq_scan from pg_stat_all_tables where relid = 'public.reactions'::regclass")

# LIVENESS WITNESSES. "Nothing was blocked" is satisfied by a run where the retirement never happened,
# or where the probe never overlapped it, so pin all three: the probe saw the work, it got observations
# in while the work ran, and the work really did the O(referencing table) scan that carries the lock.
check "the probe overlapped a running retirement"      "$(q "select saw::text from public.probe")"              "true"
check "reads landed inside it"                         "$(q "select (reads > 0)::text from public.probe")"      "true"
check "writes landed inside it"                        "$(q "select (writes > 0)::text from public.probe")"     "true"
check "the detach really scanned the referencing table" "$([ "$SCANS_AFTER" -gt "$SCANS_BEFORE" ] && echo true || echo false)" "true"

# THE CONTRACT.
check "the MANAGED PARENT is never blocked"            "$(q "select timeouts::text from public.probe")"         "0"

# And the retirement must actually have progressed, or the contract above is vacuous.
check "the partition ended up detached"                "$(q "select (count(*) = 0)::text from pg_inherits i
       join pg_class c on c.oid = i.inhrelid
      where i.inhparent = 'public.messages'::regclass and c.relname = '$CHILD'")"                                "true"
# The point of detach-then-drop: the referencing table keeps its own foreign key, and it still enforces.
check "the referencing table's FK survived"            "$(q "select count(*)::text from pg_constraint
      where conrelid = 'public.reactions'::regclass and contype = 'f' and conparentid = 0")"                     "1"

exit "$fail"
