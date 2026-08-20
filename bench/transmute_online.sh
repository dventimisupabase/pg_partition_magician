#!/usr/bin/env bash
# Pilot rung 0b (docs/pilot.md): prove a transmute is ONLINE against a customer's table, over a DSN,
# while a synthetic workload writes at the frontier and reads the hot end.
#
# NOT a CI guard. bench/transmute_lock.sh is the CI guard for the same property: it builds its own
# fixture in a local container and is verified against a mutation by ./test.sh discriminate. This is the
# field instrument for the same question, pointed at a real database that this script does not own, and
# it cannot run in CI because it needs a target and a workload. It carries its own discrimination
# instead, at run time, in the form of assertions 1, 2 and 5 below.
#
# THE CLAIM UNDER TEST. transmute splits itself across three transactions so that no ACCESS EXCLUSIVE is
# held across its O(rows) validation scan. On an idle database that claim is untestable: "no reader or
# writer was blocked" is trivially true where there are none, so it is satisfied by an execution with
# nothing to block. That is why rung 0a cannot conclude anything about online-ness and this exists.
#
# WHAT IT ASSERTS, and why each is load-bearing:
#
#   1. LIVENESS: the workload was already committing writes BEFORE the conversion started. Everything
#      below is about what happened to concurrent traffic; without traffic all of it passes vacuously,
#      which is precisely the rung-0a result wearing a rung-0b label.
#   2. LIVENESS: the probe caught the validation scan in progress. A probe that samples after the window
#      closes sees no locks and reports "nothing was held" against arbitrarily broken code.
#   3. No ACCESS EXCLUSIVE was GRANTED on the table during the scan. Note GRANTED: unlike the CI guard,
#      here a workload is running, so transmute's own AEL request legitimately QUEUES behind the
#      workload's ROW EXCLUSIVE and shows up in pg_locks ungranted. Counting a pending request as a held
#      lock would fail this against correct code.
#   4. A concurrent reader survives the scan.
#   5. LIVENESS: the workload committed writes DURING the conversion window, not merely before it. This
#      is the assertion that separates 0b from 0a. A workload that stalled the instant the conversion
#      began, for any reason including one of this harness's own, must not read as success.
#   6. No writer was QUEUED at the moment the scan was running. ROW EXCLUSIVE does not conflict with
#      the scan's SHARE UPDATE EXCLUSIVE, so a queued writer is queued behind something that should not
#      be there. This is the deterministic form of "a writer was blocked".
#   7. No writer FAILED during the window. The workload carries its own lock_timeout and counts its
#      failures, so this is the customer-visible outcome. It is deliberately kept alongside 3 and 6:
#      those detect the defect at any size, while this one only fires once the stall exceeds a real
#      client's patience. Measured against the transmute_no_commits mutation at 3M rows, 3 and 6 failed
#      and 7 still passed, because the stall was under the timeout. On a customer-sized table it would
#      not be.
#   8. The conversion succeeded, and left no in-flight record behind.
#
# The table is CONVERTED when this finishes. Run it on a clone, and re-running needs pgpm.untransmute()
# or a fresh clone.
#
# Usage: transmute_online.sh <dsn> <schema.table> <control-column> <step>
#   step: '1 month' for a time or uuid control column, '1000' for an integer one.
# Requires: bench/pilot_workload.sql installed and pgpm_probe.install() already called for this table.
set -uo pipefail

DSN="${1:?dsn}"; TABLE="${2:?schema.table}"; CONTROL="${3:?control column}"; STEP="${4:?step}"
CLIENTS=${PILOT_CLIENTS:-4}
WARMUP=${PILOT_WARMUP:-5}
MAX_CONVERT=${PILOT_MAX_CONVERT:-600}
WL_LOCK_TIMEOUT=${PILOT_LOCK_TIMEOUT:-2s}
TX_LOCK_TIMEOUT=${PILOT_TX_LOCK_TIMEOUT:-5s}
# Headroom exists for exactly this situation, so it defaults ON here rather than to transmute's own 0.
# The monolith bound rejects writes at or past `hi` for the WHOLE conversion, not just one statement,
# so a writer at the frontier can cross it if the conversion happens to span a grid boundary: a daily
# step converted at 23:59, or a monthly one converted on the last of the month. Each unit pushes `hi`
# one further step out. This is the pattern a live production conversion should use too.
BOUND_HEADROOM=${PILOT_BOUND_HEADROOM:-1}
fail=0

q() { psql "$DSN" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# The braces keep the shell's own "Terminated" job notice off stderr, which is noise in a report.
stop_workload() { [ -n "${PGB:-}" ] && { kill "$PGB"; wait "$PGB"; } 2>/dev/null; PGB=""; }
cleanup() { stop_workload; [ -n "${SCRIPT:-}" ] && rm -f "$SCRIPT"; }
trap cleanup EXIT

# ---------------------------------------------------------------- preconditions
if [ "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='pgpm_probe' and p.proname='step'")" != "1" ]; then
  echo "FAIL  pgpm_probe.step() is missing: run bench/pilot_workload.sql and call pgpm_probe.install()"
  exit 1
fi
# The workload's target must be THIS table. A failed install leaves no step() at all by design, but an
# install for a DIFFERENT table leaves a perfectly working one, and a workload driving the wrong table is
# indistinguishable from one driving the right table.
WL_TABLE=$(q "select v from pgpm_probe.meta where k='table'")
if [ "$WL_TABLE" != "$(q "select '$TABLE'::regclass::text")" ]; then
  echo "FAIL  the installed workload targets '$WL_TABLE', not '$TABLE'"
  exit 1
fi
if [ "$(q "select count(*) from pgpm.config where parent_table='$TABLE'::regclass")" != "0" ]; then
  echo "FAIL  $TABLE is already managed by pgpm; this needs an unconverted table"
  exit 1
fi
KIND=$(q "select v from pgpm_probe.meta where k='kind'")
case "$KIND" in
  id) STEP_ARG="${STEP}::bigint" ;;
  *)  STEP_ARG="interval '${STEP}'" ;;
esac

# ---------------------------------------------------------------- start the workload
SCRIPT=$(mktemp -t pilotwl.XXXXXX)
printf 'select pgpm_probe.step();\n' > "$SCRIPT"
PGOPTIONS="-c lock_timeout=$WL_LOCK_TIMEOUT" \
  pgbench "$DSN" -n -f "$SCRIPT" -c "$CLIENTS" -j "$CLIENTS" \
          -T "$((WARMUP + MAX_CONVERT))" >/tmp/pilot_pgbench.log 2>&1 &
PGB=$!

echo "warming up the workload for ${WARMUP}s at ${CLIENTS} clients..."
sleep "$WARMUP"

# ASSERTION 1. Traffic must exist before the conversion, or nothing below means anything.
PRE=$(q "select coalesce(sum(inserted),0) from pgpm_probe.workload_log")
check "the workload was writing before the conversion" "$([ "${PRE:-0}" -gt 0 ] && echo yes || echo no)" "yes"
if [ "${PRE:-0}" -le 0 ]; then
  echo "      no committed writes after ${WARMUP}s; the workload is not running. pgbench said:"
  sed 's/^/      /' /tmp/pilot_pgbench.log
  exit 1
fi
MARK=$(q "select coalesce(max(id),0) from pgpm_probe.workload_log")

# ---------------------------------------------------------------- convert, and watch
psql "$DSN" -qtA -v ON_ERROR_STOP=1 \
  -c "call pgpm.transmute('$TABLE','$CONTROL',$STEP_ARG,
                            p_bound_headroom => $BOUND_HEADROOM,
                            p_lock_timeout   => '$TX_LOCK_TIMEOUT')" \
  >/tmp/pilot_transmute.log 2>&1 &
BG=$!

# Server-side, in one round trip. Sampling from the client at ~1 sample per network round trip cannot
# reliably land inside a scan window, so the poll has to run where the locks are.
SCHEMA="${TABLE%%.*}"; REL="${TABLE##*.}"
psql "$DSN" -qtA >/dev/null 2>&1 <<PROBE
create table if not exists pgpm_probe.lockprobe (caught boolean, granted_modes text, pending_modes text, rd text);
truncate pgpm_probe.lockprobe;
do \$p\$
declare g text; p text; got boolean := false; r text := 'blocked';
begin
  for i in 1 .. 2000000 loop
    select coalesce(string_agg(distinct l.mode, ',' order by l.mode) filter (where l.granted), '(none)'),
           coalesce(string_agg(distinct l.mode, ',' order by l.mode) filter (where not l.granted), '(none)')
      into g, p
      from pg_locks l
      join pg_class c on c.oid = l.relation
      join pg_namespace n on n.oid = c.relnamespace
     where c.relname = '$REL' and n.nspname = '$SCHEMA';
    if g like '%ShareUpdateExclusiveLock%' then got := true; exit; end if;
  end loop;
  if got then
    begin
      set local lock_timeout = '5s';
      perform 1 from $TABLE limit 1;   -- would block if ACCESS EXCLUSIVE were held
      r := 'ok';
    exception when others then r := sqlstate; end;
  end if;
  insert into pgpm_probe.lockprobe values (got, g, p, r);
end \$p\$;
PROBE
wait "$BG"; TX_RC=$?

AFTER=$(q "select coalesce(max(id),0) from pgpm_probe.workload_log")
stop_workload

# ---------------------------------------------------------------- evaluate
CAUGHT=$(q  "select caught::text   from pgpm_probe.lockprobe limit 1")
GRANTED=$(q "select granted_modes  from pgpm_probe.lockprobe limit 1")
PENDING=$(q "select pending_modes  from pgpm_probe.lockprobe limit 1")
READ=$(q    "select rd             from pgpm_probe.lockprobe limit 1")
DURING_OK=$(q   "select coalesce(sum(inserted),0) from pgpm_probe.workload_log where id > $MARK and id <= $AFTER")
DURING_FAIL=$(q "select coalesce(sum(failed),0)   from pgpm_probe.workload_log where id > $MARK and id <= $AFTER")
STATES=$(q "select coalesce(string_agg(distinct last_sqlstate, ','), '(none)') from pgpm_probe.workload_log
             where id > $MARK and id <= $AFTER and last_sqlstate is not null")

check "the probe caught the validation scan in progress" "$CAUGHT" "true"
case "$GRANTED" in
  *AccessExclusiveLock*) check "no ACCESS EXCLUSIVE granted during the scan" "held: $GRANTED" "not held" ;;
  *)                     check "no ACCESS EXCLUSIVE granted during the scan" "not held" "not held" ;;
esac
check "a concurrent reader survives the scan" "$READ" "ok"
# ROW EXCLUSIVE does not conflict with the SHARE UPDATE EXCLUSIVE the scan holds, so a writer queued at
# the moment the scan is running is queued behind something else, and the only candidate is an ACCESS
# EXCLUSIVE that should already have been released. A lock-state assertion rather than a wall-clock one,
# so there is nothing to flake: added after the mutation run below showed writers PENDING while the
# survives-and-no-failures assertions both still passed, because at 3M rows the stall was under their
# timeouts.
case "$PENDING" in
  *RowExclusiveLock*) check "no writer was queued behind the conversion" "queued: $PENDING" "none queued" ;;
  *)                  check "no writer was queued behind the conversion" "none queued" "none queued" ;;
esac
check "the workload committed writes DURING the conversion" \
      "$([ "${DURING_OK:-0}" -gt 0 ] && echo yes || echo no)" "yes"
check "no writer failed during the conversion" "${DURING_FAIL:-0}" "0"
check "the conversion succeeded" "$(q "select relkind from pg_class where oid='$TABLE'::regclass")" "p"
check "no in-flight record left behind" "$(q "select count(*) from pgpm.transmute_inflight")" "0"

printf '\n  committed writes during the window : %s\n' "${DURING_OK:-0}"
printf '  writer failures during the window  : %s  (sqlstates: %s)\n' "${DURING_FAIL:-0}" "$STATES"
printf '  lock modes granted during the scan : %s\n' "$GRANTED"
printf '  lock modes PENDING during the scan : %s  (queued requests, not held)\n' "$PENDING"
if [ "$TX_RC" -ne 0 ]; then
  echo "  transmute exited $TX_RC:"; sed 's/^/    /' /tmp/pilot_transmute.log
fi
exit "$fail"
