#!/usr/bin/env bash
# Measure regrain_step's SWAP duration, attributed to named buckets (issue #345, Target 2). A
# sibling to transmute_cutover_timing.sh, not an extension of it -- the fixture is materially
# different (an already-transmuted table with a resumable regrain, not a fresh conversion).
# MEASUREMENT ONLY: prints numbers and exits 0 as long as it completed. Not wired into
# `./test.sh perf`/`discriminate` -- there is no known-good threshold to assert against.
#
# THE QUESTION. regrain_step's swap runs `suspend_incoming_fks` -> DETACH -> a reconcile backstop
# -> the attach loop -> drop the old coarse child -> `restore_incoming_fks`, all in ONE
# transaction, all while the DETACH's ACCESS EXCLUSIVE is held on the WHOLE managed parent (every
# partition, not just the child being split -- wider blast radius than transmute's cutover, which
# locks only the one table being converted). `restore_incoming_fks` runs inside that same
# transaction *deliberately* (install.sql:2253-2257: "so no other session ever observes RI off"),
# unlike transmute's incoming-FK handling, which tolerates a visible window and restores on a
# later tick. This measures whether that cost is large enough to justify a lower-blast-radius
# redesign -- it does NOT pre-suppose one, and deferring restore_incoming_fks to a later tick
# (copying transmute's pattern) would reintroduce exactly the gap this design avoids; see the
# comment above for why that is not "just" a fix.
#
# restore_incoming_fks's re-add is deliberately NOT VALID (install.sql:4513-4526; VALIDATE is left
# to a later maintain() tick), so its cost here is a metadata-only ADD CONSTRAINT, not a scan --
# the number worth measuring is LOCK WAIT under contention on the referencing table, not a
# row-count-scaling cost. That is what the contended/uncontended matrix below is for.
#
# FIXTURE GOTCHA (read before changing this script): suspend_incoming_fks/restore_incoming_fks
# operate on pgpm.dropped_fk rows, not on pg_constraint generically. An FK added directly on the
# parent AFTER transmute is never tracked there, so the swap's suspend/restore would find nothing
# for it and the DETACH would fail outright (Postgres itself refuses to detach a partition a live
# incoming FK still references). The incoming FK(s) MUST be created before transmute (with
# p_incoming_fks => 'preserve'), then pgpm.restore_incoming_fks() called once directly (bypassing
# maintain/cron) to bring them to the live "restored" state -- only then does the swap have
# anything to suspend/restore at all.
#
# MEASUREMENT MECHANISM: see transmute_cutover_timing.sh's header for the full rationale
# (log_min_duration_statement does not see nested EXECUTE'd DDL at all; auto_explain's executor
# hooks never fire for utility/DDL statements). Same mechanism here: pg_stat_statements with
# `track = 'all'` + `track_utility = on`, reset immediately before the one swap-triggering call,
# read back after. Same CONTAINER REQUIREMENT: pg_stat_statements must be preloaded --
#
#   docker run -d --name pgpm_bench17 -e POSTGRES_PASSWORD=postgres \
#     -v "$(pwd)":/repo:ro pgpm_test:17 \
#     -c shared_preload_libraries=pg_cron,pg_stat_statements \
#     -c cron.database_name=postgres -c pg_stat_statements.track=all \
#     -c pg_stat_statements.track_utility=on
#
# Usage: regrain_swap_timing.sh <container> <db_prefix> [install.sql]
set -uo pipefail
C="${1:?container}"; DBPFX="${2:?db prefix}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
qraw() { docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }

# ---- fail fast if the container was not started with pg_stat_statements preloaded ----
docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database ${DBPFX}_probe" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "${DBPFX}_probe" -qtA -c "create extension if not exists pg_stat_statements" >/tmp/pss_probe2.log 2>&1; then
  echo "FATAL: pg_stat_statements is not available in container '$C'."
  echo "It must be started with pg_stat_statements in shared_preload_libraries -- see this script's"
  echo "header comment for the exact 'docker run' invocation. Probe error:"
  cat /tmp/pss_probe2.log
  docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1
  exit 1
fi
docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1

# ---- bucket attribution query ----
# `total` is the swap-triggering call's OWN row: unlike transmute (three transactions, so its
# outer call spans phases this script does not want to measure), the LAST regrain_step tick does
# nothing but the swap once the cursor has already reached hi and the delta is already
# reconciled (both true by construction here -- the setup loop below runs every earlier tick),
# so its own total_exec_time already IS the swap's whole duration; no phase to subtract out.
#
# `(nested-wrapper)`: the same double-counting trap as transmute's `obtain` -- suspend_incoming_fks
# /restore_incoming_fks/_regrain_reconcile/_regrain_delta_purge/_regrain_delta_count are themselves
# PL/pgSQL calls whose own row already totals everything they do; their nested DDL/DML is bucketed
# individually below (suspend_fk / restore_fk / reconcile_backstop's own leaf statements), so the
# wrapper rows are excluded here rather than counted twice.
read -r -d '' BUCKET_SQL <<'SQL'
with s as (
  select query, total_exec_time as ms from pg_stat_statements
   where query not ilike 'select pg_stat_statements_reset%'
     -- pg_stat_statements is CLUSTER-WIDE, not per-session: the contended case's blocker session
     -- (its own `select count(*) from ...`/`select pg_sleep(...)`/`begin`/`commit`) runs
     -- concurrently and would otherwise land in `other`, inflating it by however long the
     -- blocker slept -- caught by a smoke run where `other` came back ~3000ms, matching the
     -- blocker's sleep almost exactly, in a case where phase 3 has nothing that should take
     -- anywhere near that long.
     and query not ilike '%pg_sleep%'
     and query not ilike 'select count(*) from public.rgt_ref%'
     and query not in ('begin', 'commit')
     and query not ilike 'set application_name%'
     and query not ilike 'set lock_timeout%'
),
total_row as (select ms from s where query ilike 'select pgpm.regrain_step(%'),
bucketed as (
  select
    case
      when query ilike 'select pgpm.regrain_step(%'                                    then '(nested-wrapper)'
      when query ilike '%pgpm.suspend_incoming_fks%'                                    then '(nested-wrapper)'
      when query ilike '%pgpm.restore_incoming_fks%'                                    then '(nested-wrapper)'
      when query ilike '%pgpm._regrain_reconcile%'                                      then '(nested-wrapper)'
      when query ilike '%pgpm._regrain_delta_purge%'                                    then '(nested-wrapper)'
      when query ilike '%pgpm._regrain_delta_count%'                                    then '(nested-wrapper)'
      when query ilike '%pgpm._own_like_parent%' or query ilike '%pgpm._analyze%'       then '(nested-wrapper)'
      when query ~* '^alter table .*detach partition'                                  then 'detach'
      when query ~* '^alter table .*attach partition .*for values'
        or query ~* 'drop constraint .*_ck'                                             then 'attach_loop'
      when query ~* '^alter table .*add constraint .*foreign key.*not valid'            then 'restore_fk'
      -- suspend_fk's drop is on the REFERENCING table, generic name (no _ck suffix); the
      -- attach loop's constraint drop above is matched first and always ends in _ck, so this
      -- catches only the FK suspend.
      when query ~* '^alter table .*drop constraint'                                   then 'suspend_fk'
      when query ~* '^drop table' or query ~* '^truncate'                              then 'drop_old_child'
      when query ~* 'pgpm_seq' or query ~* '_grid_floor.*_decode'                       then 'reconcile_backstop'
      when query ~* '^insert into pgpm\.' or query ~* '^update pgpm\.'
        or query ~* '^delete from pgpm\.'                                              then 'bookkeeping'
      else 'other'
    end as bucket,
    ms
  from s
)
select bucket, round(sum(ms)::numeric, 3) as ms,
       round((100.0 * sum(ms) / nullif((select ms from total_row), 0))::numeric, 1) as pct
  from bucketed
 where bucket <> '(nested-wrapper)'
 group by bucket
 order by ms desc;
SQL

# ---- build the fixture and drive regrain up to (but not including) the swap tick ----
# args: label rows n_fk contended(0/1)
run_case() {
  local label="$1" rows="$2" n_fk="$3" contended="$4"
  local DB="${DBPFX}_${label}"
  local target_step=$(( rows / 5 ))
  local transmute_step=$(( target_step * 6 ))   # 6 sub-ranges: 5 hold data, 1 trailing empty
  local batch=$(( target_step / 3 ))

  docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
  docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null
  q "create extension if not exists pg_stat_statements" >/dev/null

  q "create table public.rgt (id bigint primary key, v text)" >/dev/null
  q "insert into public.rgt select g, repeat('x',40) from generate_series(1,$rows) g" >/dev/null

  {
    for i in $(seq 1 "$n_fk"); do
      echo "create table public.rgt_ref_$i (id int primary key, rgt_id bigint references public.rgt(id));"
      echo "insert into public.rgt_ref_$i select g, g from generate_series(1,1000) g;"
    done
  } | docker exec -i "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f - >/dev/null

  q "vacuum analyze public.rgt" >/dev/null

  qraw "call pgpm.transmute('public.rgt'::regclass, 'id', ${transmute_step}::bigint, p_incoming_fks => 'preserve')" >/tmp/rgt_bench_${label}.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FATAL: transmute failed for case '$label':"; cat /tmp/rgt_bench_${label}.log; exit 1
  fi
  q "select pgpm.restore_incoming_fks('public.rgt'::regclass)" >/dev/null
  # freeze the monolith: advance max(id) past its hi so the frontier's grid floor moves beyond it
  # (obtain's default forward grid, built by transmute above, already covers this id).
  q "insert into public.rgt values ($((transmute_step + 1)), 'frontier')" >/dev/null

  # drive every tick up to (but not including) the swap -- copied from
  # regrain_outgoing_fk_lock.sh's setup loop: re-fetch cursor/child name each iteration, since
  # regrain_step's first real tick can rename the source child (#266).
  docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "
  do \$setup\$
  declare s text; n int := 0; v_cursor text; v_hi text; v_child name;
  begin
    select hi into v_hi from pgpm.part
     where parent_table = 'public.rgt'::regclass and attached and lo::numeric = 0;
    loop
      select regrain_cursor into v_cursor from pgpm.config where parent_table = 'public.rgt'::regclass;
      exit when v_cursor is not null and v_cursor::numeric >= v_hi::numeric;
      select child_name into v_child from pgpm.part
       where parent_table = 'public.rgt'::regclass and attached and lo::numeric = 0;
      s := pgpm.regrain_step('public.rgt'::regclass, v_child, '$target_step', $batch);
      n := n + 1;
      if n > 500 then raise exception 'regrain setup did not converge (last status: %)', s; end if;
    end loop;
  end \$setup\$;" >/tmp/rgt_setup_${label}.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FATAL: regrain setup did not converge for case '$label':"; cat /tmp/rgt_setup_${label}.log; exit 1
  fi

  local v_child
  v_child=$(q "select child_name from pgpm.part where parent_table = 'public.rgt'::regclass and attached and lo::numeric = 0")

  local BLOCKER=""
  if [ "$contended" = "1" ]; then
    docker exec "$C" psql -U postgres -d "$DB" -qtA \
      -c "set application_name = 'pgpm_swap_blocker'" \
      -c "begin; select count(*) from public.rgt_ref_1; select pg_sleep(3); commit;" >/dev/null 2>&1 &
    BLOCKER=$!
    local HELD=false
    for _ in $(seq 1 50); do
      n=$(q "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
              where c.relname = 'rgt_ref_1' and l.granted
                and l.pid = (select pid from pg_stat_activity where application_name = 'pgpm_swap_blocker')")
      if [ "${n:-0}" -ge 1 ]; then HELD=true; break; fi
      sleep 0.1
    done
    if [ "$HELD" != "true" ]; then
      echo "FATAL: contended case '$label' -- the blocker never acquired its lock"; exit 1
    fi
  fi

  q "select pg_stat_statements_reset()" >/dev/null
  docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
    -c "set lock_timeout = '30s'" \
    -c "select pgpm.regrain_step('public.rgt'::regclass, '$v_child', '$target_step', $batch)" \
    >/tmp/rgt_swap_${label}.log 2>&1
  local rc=$?
  [ -n "$BLOCKER" ] && wait "$BLOCKER" 2>/dev/null
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: the swap tick failed for case '$label':"; cat /tmp/rgt_swap_${label}.log; exit 1
  fi
  if ! grep -q "^swapped:" /tmp/rgt_swap_${label}.log; then
    echo "FATAL: case '$label' -- the timed call did not report a swap (setup did not fully drain):"
    cat /tmp/rgt_swap_${label}.log
    exit 1
  fi

  echo
  echo "### $label (ROWS=$rows TARGET_STEP=$target_step N_INCOMING_FK=$n_fk contended=$contended)"
  echo
  echo "| bucket | ms | % of swap total |"
  echo "|---|---|---|"
  docker exec "$C" psql -U postgres -d "$DB" -qtA -F'|' -c "$BUCKET_SQL" | while IFS='|' read -r bucket ms pct; do
    [ -z "$bucket" ] && continue
    echo "| $bucket | $ms | $pct |"
  done

  docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
}

ROWS=${ROWS:-2000000}

echo "# Target 2: regrain_step swap timing"
echo "Container: $C   Install: $INSTALL"

for n_fk in 1 5 10; do
  run_case "fk${n_fk}_uncontended" "$ROWS" "$n_fk" 0
  run_case "fk${n_fk}_contended"   "$ROWS" "$n_fk" 1
done

exit 0
