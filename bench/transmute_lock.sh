#!/usr/bin/env bash
# Guard transmute against re-acquiring a data-coupled lock (issue #275). Run by CI (`./test.sh perf`).
#
# THE BAR (issue #263's acceptance rule): a blocking lock may last milliseconds, but it must never last a
# duration coupled to data size. transmute's validation scan is O(rows); the whole point of splitting the
# conversion into three transactions is that the scan runs under SHARE UPDATE EXCLUSIVE, which blocks
# nobody, instead of under the ACCESS EXCLUSIVE the preceding ADD takes.
#
# Before the split, both locks were held at once and a plain SELECT died on lock_timeout. That regression
# would be invisible to the pgTAP suite: asserting it needs a SECOND SESSION observing a first one
# mid-scan, and pgTAP gives one session per file. Hence a shell harness, like bench/regrain_perf.sh.
#
# It asserts LOCK MODES and whether a concurrent reader survives, not wall-clock, so there is nothing to
# flake on a shared runner.
#
# Usage: transmute_lock.sh <container> <db>
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROWS=${ROWS:-8000000}
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-52s %s\n' "$1" "$2"
  else printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f /repo/pgpm_core/install.sql >/dev/null 2>&1

q "create table public.tl (id bigint primary key, v text)" >/dev/null
q "insert into public.tl select g, repeat('x',80) from generate_series(1,$ROWS) g" >/dev/null
q "vacuum analyze public.tl" >/dev/null

# Convert in the background and observe from a second session. The observation runs SERVER-SIDE, in one
# psql call: polling with repeated `docker exec` costs ~100 ms per sample, which is longer than the scan
# itself, so the probe could never land inside the window and every assertion passed vacuously. Seen
# happening on both the fixed and the broken code while writing this, which is why the harness now demands
# positive evidence that it caught the scan and treats missing it as a FAIL rather than a pass.
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "call pgpm.transmute('public.tl','id', $((ROWS * 2))::bigint)" >/tmp/tl_bg.log 2>&1 &
BG=$!

docker exec "$C" psql -U postgres -d "$DB" -qtA -c "
create table if not exists public.probe (caught boolean, modes text, rd text);
do \$p\$
declare m text; got boolean := false; r text := 'blocked';
begin
  for i in 1 .. 2000000 loop
    select coalesce(string_agg(distinct l.mode, ',' order by l.mode), '(none)') into m
      from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'tl';
    if m like '%ShareUpdateExclusiveLock%' then got := true; exit; end if;
  end loop;
  if got then
    begin
      set local lock_timeout = '5s';
      perform 1 from public.tl limit 1;   -- would block if ACCESS EXCLUSIVE were still held
      r := 'ok';
    exception when others then r := sqlstate; end;
  end if;
  insert into public.probe values (got, m, r);
end \$p\$;" >/dev/null 2>&1
wait $BG

CAUGHT=$(q "select caught::text from public.probe limit 1")
MODES=$(q  "select modes        from public.probe limit 1")
READ=$(q   "select rd           from public.probe limit 1")

check "the probe caught the validation scan in progress" "$CAUGHT" "true"
# The question is precisely: WHILE the validate holds SHARE UPDATE EXCLUSIVE, is ACCESS EXCLUSIVE also
# held? Before the split it was, because the preceding ADD never released it.
case "$MODES" in
  *AccessExclusiveLock*) check "ACCESS EXCLUSIVE is not held during the scan" "held: $MODES" "not held" ;;
  *)                     check "ACCESS EXCLUSIVE is not held during the scan" "not held" "not held" ;;
esac
check "a concurrent reader survives the scan" "$READ" "ok"
check "the conversion itself succeeded"       "$(q "select relkind from pg_class where oid='public.tl'::regclass")" "p"
check "no in-flight record left behind"       "$(q "select count(*) from pgpm.transmute_inflight")" "0"

exit "$fail"
