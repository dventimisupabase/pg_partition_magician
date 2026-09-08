#!/usr/bin/env bash
# Guard regrain_step's swap against a scan-under-lock when the managed table has an outgoing
# foreign key (issue #348). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never
# last a duration coupled to data size.
#
# A fine child is created via `like ... including constraints`, which never copies a FOREIGN KEY
# (no LIKE option does). Before the fix, that leaves every fine child with no outgoing FK at all,
# so the swap's ATTACH PARTITION forces PostgreSQL to validate the parent's outgoing FK for that
# partition from scratch -- an O(rows) scan of the CHILD, inside the ATTACH statement, under
# whatever lock the swap already holds on the managed parent. Measured directly (not by this
# probe, which can only detect a block, not time one): at this guard's default (CHILD_ROWS=
# 8,000,000), attaching that partition with its FK pre-validated took ~20 ms; the identical
# attach without pre-validating took ~532 ms for the same row count -- and that gap is O(rows),
# so it grows without bound on a bigger partition, which is exactly how this reached a
# production statement_timeout.
#
# The fix (mirroring the bound CHECK, which already gets this treatment) adds each of the
# parent's outgoing FKs to the fine child, NOT VALID, then VALIDATEs it immediately -- while the
# child is still empty, so the scan costs nothing. By the swap's ATTACH, PostgreSQL adopts the
# already-validated constraint instead of re-scanning.
#
# The assertion is the consequence an operator sees: a plain INSERT into the MANAGED PARENT, with
# a lock_timeout shorter than the unfixed scan's duration but comfortably longer than the fixed
# swap's own duration, must never time out while a swap with an outgoing FK runs. At this guard's
# default (CHILD_ROWS=8,000,000), the probe itself measured 0 timeouts out of 342 write attempts
# against a fixed install and 10 out of 646 against an unfixed one -- the same gap the direct
# timing above shows, just observed as blocked writes instead of milliseconds.
#
# The fixture is built so the swap has exactly ONE non-trivial fine child: transmute's own step
# is twice regrain's target step, so the coarse monolith covers two sub-ranges, all CHILD_ROWS
# rows landing in the first and nothing in the second. That keeps the swap's cost concentrated in
# one ATTACH statement (one continuous lock hold) rather than spread thin across many small ones,
# which is easier for a probe polling on a commit-per-iteration cadence to actually catch.
#
# Usage: regrain_outgoing_fk_lock.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead,
# to prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
REF_ROWS=${REF_ROWS:-1000}
CHILD_ROWS=${CHILD_ROWS:-8000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f "$INSTALL" >/dev/null 2>&1

q "create table public.rofk_ref (id int primary key)" >/dev/null
q "insert into public.rofk_ref select g from generate_series(1, $REF_ROWS) g" >/dev/null
q "create table public.rofk (id bigint primary key,
     ref_id int not null references public.rofk_ref(id), payload text)" >/dev/null
q "insert into public.rofk select g, ((g % $REF_ROWS) + 1), 'x' from generate_series(1, $CHILD_ROWS) g" >/dev/null
q "call pgpm.transmute('public.rofk','id', $((CHILD_ROWS * 2))::bigint, p_paused => false)" >/dev/null
q "insert into public.rofk values ($((CHILD_ROWS * 2 + 1)), 1, 'frontier')" >/dev/null   # freeze the monolith

# Pre-copy everything synchronously, stopping once the cursor reaches the coarse child's own hi
# (fully copied, not yet swapped) -- so the ONE call left to run is the swap itself. Re-fetches
# the coarse child's name every tick: regrain_step's first tick can RENAME it (#266), so a name
# cached before that rename goes stale.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$setup\$
declare s text; n int := 0; v_cursor text; v_hi text; v_child name;
begin
  select hi into v_hi from pgpm.part
   where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
  loop
    select regrain_cursor into v_cursor from pgpm.config where parent_table = 'public.rofk'::regclass;
    exit when v_cursor is not null and v_cursor::numeric >= v_hi::numeric;
    select child_name into v_child from pgpm.part
     where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
    s := pgpm.regrain_step('public.rofk'::regclass, v_child, '$CHILD_ROWS', $((CHILD_ROWS / 4)));
    n := n + 1;
    if n > 500 then raise exception 'regrain setup did not converge'; end if;
  end loop;
end \$setup\$;" >/dev/null

q "vacuum analyze public.rofk" >/dev/null
q "vacuum analyze public.rofk_ref" >/dev/null
q "create table public.probe (attempts int, timeouts int, saw boolean)" >/dev/null
q "create table public.done (x int)" >/dev/null

# background: the swap tick, and only the swap tick -- the coarse child's name is looked up fresh
# right before the call, same as setup above.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$swap\$
declare v_child name;
begin
  select child_name into v_child from pgpm.part
   where parent_table = 'public.rofk'::regclass and attached and lo::numeric = 0;
  perform pgpm.regrain_step('public.rofk'::regclass, v_child, '$CHILD_ROWS', $((CHILD_ROWS / 4)));
end \$swap\$;" \
  -c "insert into public.done values (1)" >/tmp/rofk_bg.log 2>&1 &
BG=$!

# COMMIT after every attempt. Locks are held to transaction end and a DO block is ONE transaction, so
# a probe that just loops pins its own lock and blocks the very ATTACH it is trying to observe, which
# makes the run prove nothing. Learned on bench/maintain_lock.sh.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
do \$p\$
declare n int := 0; t int := 0; saw boolean := false;
begin
  for i in 1 .. 2000000 loop
    exit when exists(select 1 from pg_stat_activity
                      where datname = current_database() and pid <> pg_backend_pid()
                        and query like '%regrain_step%' and state = 'active');
    commit;
  end loop;
  saw := true;
  while not exists(select 1 from public.done) loop
    begin
      set local lock_timeout = '50ms';
      insert into public.rofk (id, ref_id, payload) values ($((CHILD_ROWS * 4)) + n, 1, 'live write');
    exception when others then t := t + 1; end;
    n := n + 1;
    commit;
  end loop;
  insert into public.probe values (n, t, saw);
end \$p\$;" >/dev/null 2>&1
wait $BG

check "the probe overlapped a running swap"          "$(q "select saw::text from public.probe")"          "true"
check "at least one write landed inside it"          "$(q "select (attempts > 0)::text from public.probe")" "true"
check "writes to the MANAGED PARENT are not blocked" "$(q "select timeouts::text from public.probe")"      "0"
# conparentid = 0 picks the top-level constraint. An FK referencing a PARTITIONED table also gets one
# pg_constraint row per partition of the referencING side, so an unfiltered count would report one
# per attached partition, not 1.
check "the outgoing FK is intact and adopted, not duplicated" "$(q "select count(*)::text from pg_constraint
       where confrelid = 'public.rofk_ref'::regclass and contype = 'f' and conparentid = 0")" "1"

exit "$fail"
