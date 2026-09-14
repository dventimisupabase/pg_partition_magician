#!/usr/bin/env bash
# Measure regrain_step's SWAP duration, attributed to named buckets (issue #345, Target 2). A
# sibling to transmute_cutover_timing.sh, not an extension of it -- the fixture is materially
# different (an already-transmuted table with a resumable regrain, not a fresh conversion).
# MEASUREMENT ONLY: prints numbers and exits 0 as long as it completed. Not wired into
# `./test.sh perf`/`discriminate` -- there is no known-good threshold to assert against.
#
# POST-#378 STATUS: the fix landed (regrain_step's swap now scopes its own restore_incoming_fks
# call to exactly the FK(s) it suspended in that same call, install.sql, rather than opportunistically
# restoring every not-yet-restored row for the parent). The contended case's fixture is unchanged
# (a "held-back" FK, never suspended by this swap, with a lock pre-acquired on its referencing
# table before the swap even starts) -- what changed is the expected outcome. Before the fix, this
# showed restore_fk eating ~99% of swap duration; after, the swap never goes near that table at
# all, so restore_fk should look just like the uncontended case despite the blocker's lock. The
# liveness witness at the bottom of run_case asserts exactly that, and fails loudly on a
# regression back to the old behavior.
#
# THE QUESTION. regrain_step's swap runs `suspend_incoming_fks` -> DETACH -> a reconcile backstop
# -> the attach loop -> drop the old coarse child -> `restore_incoming_fks`, all in ONE
# transaction. Only DETACH onward runs under the parent's own ACCESS EXCLUSIVE (every partition,
# not just the child being split -- wider blast radius than transmute's cutover, which locks only
# the one table being converted): `suspend_incoming_fks` runs BEFORE the DETACH and takes nothing
# stronger than ACCESS SHARE on the parent itself, confirmed directly (a plain SELECT/INSERT
# against the parent completed instantly while an earlier version of this script's probe sat
# blocked inside `suspend_incoming_fks` -- that version wrongly contended the referencing table
# before the swap call even started, which only delays how soon the real locked window begins,
# and never blocks any other session's access to the parent itself). So the number worth
# measuring is contention landing DURING the actually-locked window -- DETACH through
# `restore_fk` -- not before it. `restore_incoming_fks` runs inside that locked window
# *deliberately* (install.sql:2253-2257: "so no other session ever observes RI off"), unlike
# transmute's incoming-FK handling, which tolerates a visible window and restores on a later
# tick. This measures whether that cost is large enough to justify a lower-blast-radius redesign
# -- it does NOT pre-suppose one, and deferring restore_incoming_fks to a later tick (copying
# transmute's pattern) would reintroduce exactly the gap this design avoids.
#
# restore_incoming_fks's re-add is deliberately NOT VALID (install.sql:4513-4526; VALIDATE is left
# to a later maintain() tick), so its cost here is a metadata-only ADD CONSTRAINT, not a scan --
# the number worth measuring is LOCK WAIT under contention on the referencing table, not a
# row-count-scaling cost. That is what the contended/uncontended matrix below is for.
#
# HOW THE CONTENDED CASE LANDS ITS CONTENTION IN THE RIGHT WINDOW, DETERMINISTICALLY. A first
# version of this script tried to catch the moment by having a second session poll pg_locks for
# the parent's own ACCESS EXCLUSIVE lock (which appears the instant DETACH runs) and race to grab
# the referencing table's lock before restore_fk got there. That race was lost consistently, even
# after eliminating every avoidable source of latency (warming up the poll query's plan cache,
# pre-warming the lock acquisition itself): actually acquiring a fresh ACCESS EXCLUSIVE table lock
# measured ~13-40ms in this environment, comfortably larger than the whole detach-to-restore_fk
# window for any realistic (small) fine-child count. Widening the fixture to thousands of fine
# children did make the race winnable, but for the wrong reason -- it turned out to make
# `restore_incoming_fks`'s own "gate 2" preamble (a pg_class scan whose cost grows with existing
# partition count) and Postgres's own per-partition ATTACH overhead so slow on their own that the
# *uncontended* baseline already exceeded the "was this actually contended?" threshold. That would
# have been a false-positive result reported with confidence -- exactly the passing-for-the-
# wrong-reason failure mode this project's CLAUDE.md warns about, just surfacing in a measurement
# script rather than a guard.
#
# The fix is to not race at all. `suspend_incoming_fks` only touches `pgpm.dropped_fk` rows with
# `restored_at IS NOT NULL` (currently-restored FKs); `restore_incoming_fks` only touches rows
# with `restored_at IS NULL` (not yet restored). So one FK -- the LAST one processed -- is
# deliberately left (or put back) in the "not yet restored" state before the swap ever starts:
# `suspend_incoming_fks` will never touch its referencing table at all (it isn't in the restored
# set), so a lock pre-acquired on it, before the swap call even begins, is *structurally*
# incapable of contending `suspend_fk` -- and `restore_incoming_fks` WILL try to re-add exactly
# that FK, later, from inside the real locked window, and queue behind the pre-held lock. No
# timing, no polling, no race: the isolation is guaranteed by which processing set each function
# reads from, not by which statement happens to run faster.
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
      -- restore_incoming_fks's OWN "gate 2" preamble (install.sql ~4463-4479: is any not-yet-
      -- attached child in flight?) scans pg_class filtering by partition-name pattern -- a plain
      -- SELECT, not matched by any DDL pattern above, so it fell into `other` uncategorized.
      -- Found by diagnosing why `other` grew with fine-child count even after excluding every
      -- other nested-wrapper row: it is O(existing partitions), same shape as attach_loop's own
      -- scaling, and belongs to restore_fk's own cost, not a mystery residual.
      when query ~* '^select c\.relname\s+from pg_class c'                              then 'restore_fk'
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
  # A "handful" of fine children, per the issue's own fixture spec -- realistic, not inflated.
  # Kept the SAME for both contended and uncontended: the contended case no longer needs a wider
  # window (see header), so there is no reason for its fixture to differ and every reason not to
  # (a different fixture size would make the two numbers harder to compare).
  local n_fine=${N_FINE:-10}
  local target_step=$(( rows / n_fine ))
  local transmute_step=$(( target_step * (n_fine + 1) ))   # +1 sub-range: trailing, empty
  # batch must be STRICTLY greater than target_step: regrain_step only advances the cursor past a
  # sub-range when a tick copies FEWER rows than its batch (`v_moved < v_batch`), so batch ==
  # target_step exactly needs two ticks per sub-range (the first copies exactly batch and does not
  # advance, the second finds nothing left and does) -- caught by a run where the setup loop
  # exceeded its cap needing ~2x the expected tick count.
  local batch=$(( target_step + 1 ))

  # Terminate any lingering connection before dropping: a prior run's blocker session (backgrounded,
  # not always fully closed by the time its script exits) can keep a DROP DATABASE from succeeding,
  # and the DROP's own errors were being silently swallowed -- which means a rerun could silently
  # operate against a STALE database from an earlier, unrelated attempt instead of a fresh one.
  # Caught exactly this way: a stale run's leftover fine-child tables tripped
  # restore_incoming_fks's own "in-flight child" gate and made it return early with no error.
  docker exec "$C" psql -U postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
  sleep 0.2
  docker exec "$C" psql -U postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $DB" \
    || { echo "FATAL: could not drop database $DB (stale connection?)"; exit 1; }
  docker exec "$C" psql -U postgres -v ON_ERROR_STOP=1 -q -c "create database $DB" \
    || { echo "FATAL: could not create database $DB"; exit 1; }
  docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null
  q "create extension if not exists pg_stat_statements" >/dev/null

  q "create table public.rgt (id bigint primary key, v text)" >/dev/null
  q "insert into public.rgt select g, repeat('x',40) from generate_series(1,$rows) g" >/dev/null

  {
    for i in $(seq 1 "$n_fk"); do
      echo "create table public.rgt_ref_$i (id int primary key, rgt_id bigint references public.rgt(id));"
      echo "insert into public.rgt_ref_$i select g, g from generate_series(1,1000) g;"
    done
    if [ "$contended" = "1" ]; then
      # see below: a hidden extra FK, not part of N_INCOMING_FK, that exists purely so
      # suspend_incoming_fks always has something to suspend in this swap.
      echo "create table public.rgt_ref_trigger (id int primary key, rgt_id bigint references public.rgt(id));"
      echo "insert into public.rgt_ref_trigger select g, g from generate_series(1,1000) g;"
    fi
  } | docker exec -i "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f - >/dev/null

  q "vacuum analyze public.rgt" >/dev/null

  qraw "call pgpm.transmute('public.rgt'::regclass, 'id', ${transmute_step}::bigint, p_incoming_fks => 'preserve')" >/tmp/rgt_bench_${label}.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FATAL: transmute failed for case '$label':"; cat /tmp/rgt_bench_${label}.log; exit 1
  fi
  q "select pgpm.restore_incoming_fks('public.rgt'::regclass)" >/dev/null

  # CONTENDED ONLY: put the LAST FK (rgt_ref_$n_fk) back into the "not yet restored" state --
  # actually drop its constraint (not just forge the bookkeeping row, which would make
  # restore_incoming_fks's later re-add collide with a constraint that still exists) and clear
  # its dropped_fk.restored_at. suspend_incoming_fks reads only restored_at IS NOT NULL rows, so
  # it will never touch this one; restore_incoming_fks reads only restored_at IS NULL rows, so it
  # WILL try to re-add this one, later, from inside the real locked window. This is what lets a
  # lock pre-acquired before the swap even starts contend restore_fk specifically, with no race.
  #
  # rgt_ref_trigger stays normally restored throughout, on purpose: regrain_step's swap only
  # calls restore_incoming_fks AT ALL when suspend_incoming_fks suspended at least one FK in that
  # SAME call (`if v_fk > 0`, install.sql ~2289). For N_INCOMING_FK=1, holding back the only real
  # FK left suspend_incoming_fks with nothing to do (v_fk=0), so restore_incoming_fks was never
  # even called and the whole contended run silently measured nothing -- caught because the swap
  # returned in ~8ms with no wait at all despite a "successful" precondition check. The trigger FK
  # guarantees v_fk >= 1 regardless of N_INCOMING_FK, without being part of the reported count.
  if [ "$contended" = "1" ]; then
    local held_conname
    held_conname=$(q "select constraint_name from pgpm.dropped_fk
                        where parent_table = 'public.rgt'::regclass
                          and referencing_table = 'public.rgt_ref_${n_fk}'::regclass")
    qraw "alter table public.rgt_ref_${n_fk} drop constraint ${held_conname}" >/dev/null
    qraw "update pgpm.dropped_fk set restored_at = null
           where parent_table = 'public.rgt'::regclass
             and referencing_table = 'public.rgt_ref_${n_fk}'::regclass" >/dev/null
  fi

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
      if n > $((n_fine + 100)) then raise exception 'regrain setup did not converge (last status: %)', s; end if;
    end loop;
  end \$setup\$;" >/tmp/rgt_setup_${label}.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FATAL: regrain setup did not converge for case '$label':"; cat /tmp/rgt_setup_${label}.log; exit 1
  fi

  local v_child
  v_child=$(q "select child_name from pgpm.part where parent_table = 'public.rgt'::regclass and attached and lo::numeric = 0")

  # PRECONDITION CHECK (contended only): confirm the fixture manipulation actually left things in
  # the state the whole design depends on -- (n_fk-1) real FKs restored plus the trigger FK, so
  # n_fk total restored, and exactly 1 not (the held-back real FK) -- before spending time on the
  # timed call. A cheap, fast-failing sanity check rather than a confusing report.
  if [ "$contended" = "1" ]; then
    local restored_n unrestored_n
    restored_n=$(q "select count(*) from pgpm.dropped_fk where parent_table='public.rgt'::regclass and restored_at is not null")
    unrestored_n=$(q "select count(*) from pgpm.dropped_fk where parent_table='public.rgt'::regclass and restored_at is null")
    if [ "$restored_n" != "$n_fk" ] || [ "$unrestored_n" != "1" ]; then
      echo "FATAL: case '$label' -- fixture precondition failed (restored=$restored_n, unrestored=$unrestored_n,"
      echo "expected restored=$n_fk, unrestored=1). The isolation this design depends on is not in place."
      exit 1
    fi
  fi

  local BLOCKER=""
  if [ "$contended" = "1" ]; then
    docker exec "$C" psql -U postgres -d "$DB" -qtA \
      -c "set application_name = 'pgpm_swap_blocker'" \
      -c "begin; lock table public.rgt_ref_${n_fk} in access exclusive mode; select pg_sleep(3); commit;" \
      >/tmp/rgt_blocker_${label}.log 2>&1 &
    BLOCKER=$!
    local HELD=false
    for _ in $(seq 1 50); do
      n=$(q "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
              where c.relname = 'rgt_ref_${n_fk}' and l.granted
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

  local BUCKET_OUT
  BUCKET_OUT=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -F'|' -c "$BUCKET_SQL")

  # LIVENESS WITNESS (post-#378 fix): regrain_step's swap now scopes its own restore_incoming_fks
  # call to exactly the FK(s) it suspended in this same call (snapshotted before suspending), so
  # the held-back FK on rgt_ref_${n_fk} -- never suspended by this swap, since it was already
  # unrestored going in -- is never touched by the swap at all anymore. The blocker's lock on it
  # should therefore have NO EFFECT: confirm restore_fk's measured time stays near its uncontended
  # baseline despite the blocker holding a conflicting lock on it for ~3s. Before the fix, this
  # same fixture showed restore_fk at ~99% of swap duration (the risk #378 asked about); after the
  # fix, it should look just like the uncontended case, because the swap no longer goes near that
  # table. Treat a jump back to the old behavior as FATAL, not a silent regression.
  if [ "$contended" = "1" ]; then
    local RESTORE_FK_MS
    RESTORE_FK_MS=$(echo "$BUCKET_OUT" | awk -F'|' '$1 == "restore_fk" {print $2}')
    if [ -z "$RESTORE_FK_MS" ] || ! awk -v v="${RESTORE_FK_MS:-0}" 'BEGIN{exit !(v < 1000)}'; then
      echo "FATAL: contended case '$label' -- restore_fk's measured time (${RESTORE_FK_MS:-<missing>} ms)"
      echo "reflects having waited on the blocker's ~3s hold on rgt_ref_${n_fk} -- the swap should"
      echo "never touch that table at all post-#378 fix. This looks like a regression back to the"
      echo "pre-fix behavior, not the fix working."
      exit 1
    fi
  fi

  echo
  echo "### $label (ROWS=$rows TARGET_STEP=$target_step N_INCOMING_FK=$n_fk contended=$contended)"
  echo
  echo "| bucket | ms | % of swap total |"
  echo "|---|---|---|"
  echo "$BUCKET_OUT" | while IFS='|' read -r bucket ms pct; do
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
