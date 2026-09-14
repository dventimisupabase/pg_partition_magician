#!/usr/bin/env bash
# Measure transmute's PHASE 3 (the cutover) duration, attributed to named buckets (issue #345,
# Target 1). MEASUREMENT ONLY: prints numbers and exits 0 as long as it completed. Not wired into
# `./test.sh perf`/`discriminate` -- there is no known-good threshold to assert against, and this
# is not a guard against a defect, it is the evidence that decides whether #344's two deferred
# reorderings (the outgoing-FK re-add, building the forward grid before the attach) are worth a
# follow-up issue at all.
#
# WHY NOT `log_min_duration_statement` (what the issue originally sketched). Spiked directly: it
# only logs the top-level statement a client submits. `call pgpm.transmute(...)` produced exactly
# one log line; none of phase 3's `execute format(...)`-driven DDL (the renames, attaches, grants,
# ...) is logged at all. `auto_explain` was considered next and also rejected: its executor hooks
# never fire for utility/DDL statements (ALTER TABLE, GRANT, CREATE POLICY, COMMENT ON, ...), which
# is nearly everything phase 3 does.
#
# WHAT ACTUALLY WORKS, spiked and confirmed: pg_stat_statements with `track = 'all'` (records
# statements nested inside procedures/functions, not just top-level calls) and `track_utility = on`
# (records DDL/utility statements, not just DML). Reset counters, run ONE `call
# pgpm.transmute(...)`, then read pg_stat_statements back: every nested statement -- including
# every ALTER/CREATE/GRANT/COMMENT the cutover runs -- comes back as its own row with an exact
# `total_exec_time`, identifiers intact (constants are normalized to $N, table/column/role names
# are not). This is more precise than log-timestamp deltas (Postgres's own measured execution
# time, not millisecond-granularity log timestamps) and needs no shell-side parsing at all: the
# whole attribution is one SQL query.
#
# CONTAINER REQUIREMENT this introduces: pg_stat_statements needs shared memory allocated at
# postmaster start, so it must be in `shared_preload_libraries` -- it cannot be `LOAD`ed
# mid-session the way auto_explain can. The stock `pgpm_test:17` image already ships
# pg_stat_statements.so (it is a stock contrib module; no Dockerfile change needed to obtain it),
# but `./test.sh`'s own container does not preload it, and this script deliberately does not touch
# the shared Dockerfile/docker-compose.yml/test.sh -- every other track depends on that image
# staying exactly as it is. Stand up a throwaway container from the already-built image instead:
#
#   docker run -d --name pgpm_bench17 -e POSTGRES_PASSWORD=postgres \
#     -v "$(pwd)":/repo:ro pgpm_test:17 \
#     -c shared_preload_libraries=pg_cron,pg_stat_statements \
#     -c cron.database_name=postgres -c pg_stat_statements.track=all \
#     -c pg_stat_statements.track_utility=on
#
# Usage: transmute_cutover_timing.sh <container> <db_prefix> [install.sql]
# <db_prefix> is a prefix; each fixture case gets its own throwaway database (<prefix>_<case>)
# since transmute only runs once per table. The install path defaults to the real one.
set -uo pipefail
C="${1:?container}"; DBPFX="${2:?db prefix}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
qraw() { docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }

# ---- fail fast if the container was not started with pg_stat_statements preloaded ----
docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database ${DBPFX}_probe" >/dev/null 2>&1
if ! docker exec "$C" psql -U postgres -d "${DBPFX}_probe" -qtA -c "create extension if not exists pg_stat_statements" >/tmp/pss_probe.log 2>&1; then
  echo "FATAL: pg_stat_statements is not available in container '$C'."
  echo "It must be started with pg_stat_statements in shared_preload_libraries -- see this script's"
  echo "header comment for the exact 'docker run' invocation. Probe error:"
  cat /tmp/pss_probe.log
  docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1
  exit 1
fi
docker exec "$C" psql -U postgres -q -c "drop database if exists ${DBPFX}_probe" >/dev/null 2>&1

# ---- bucket attribution query, shared by every case ----
# Excluded entirely (not counted in ANY bucket, not counted in `total`): the wrapper CALL rows
# themselves (they would double-count everything nested inside them), and phase 1/phase 2's own
# statements (the bound CHECK add and its validation) -- this script measures PHASE 3 only. Every
# other preflight statement (index/trigger/FK shape checks, the two frontier/min-max selects) is
# cheap catalog or PK-indexed lookups regardless of ROWS and is left uncategorized in `other`
# rather than enumerated one by one; it is not the O(rows) cost this issue is chasing.
#
# `obtain` is matched on ITS OWN WRAPPER ROW ('select pgpm.obtain(...)'), not by re-summing its
# nested create-table/insert statements -- summing both would double count. Its nested rows are
# therefore explicitly excluded from every other bucket too (the 'not (...)' clause before the
# final else), so they fall out of the count entirely rather than leaking into `other`.
read -r -d '' BUCKET_SQL <<'SQL'
with s as (
  select query, total_exec_time as ms from pg_stat_statements
   where query not ilike 'call pgpm.transmute%'
     and query not ilike 'call pgpm._transmute%'
     and query not ilike '%add constraint pgpm_monolith_bound%'
     and query not ilike '%validate constraint pgpm_monolith_bound%'
     and query not ilike 'select pg_stat_statements_reset%'
),
bucketed as (
  select
    case
      when query ilike 'select pgpm.obtain(%'                                         then 'obtain'
      -- obtain's own nested statements (its whole call subtree, arbitrarily deep --
      -- _create_partition, _own_like_parent, _analyze, and the DDL/bookkeeping they in turn
      -- execute): counted ONCE via the wrapper row above, excluded here so they are not also
      -- double-counted into pk_index/bookkeeping/other. Found by running a small fixture and
      -- diffing `other` against `obtain`'s own ms -- they were near-identical before these
      -- exclusions were added, which is what exposed the double count.
      when query ilike '%pgpm._create_partition%'                                      then '(obtain-nested)'
      when query ilike 'create table % partition of %for values%'                      then '(obtain-nested)'
      when query ilike 'insert into pgpm.part (parent_table, child_name, lo, hi) values%' then '(obtain-nested)'
      when query ilike 'insert into pgpm.log (parent_table, action, lo, hi, method) values%' then '(obtain-nested)'
      when query ilike '%pgpm._own_like_parent%' or query ilike '%pgpm._analyze%'       then '(obtain-nested)'
      when query ~* '^alter table .*rename to'                                          then 'rename'
      when query ~* 'drop identity' or query ~* 'add generated .*as identity'
        or (query ~* '^alter table .*alter column' and query ~* 'set not null')         then 'identity'
      when query ~* '^alter table .*attach partition .*for values'                     then 'attach'
      when query ~* '^alter table .*add constraint .*foreign key'                       then 'fk'
      when query ~* '^grant ' or query ~* 'row level security'
        or query ~* '^create policy' or query ~* '^comment on'                         then 'grants_rls_policies_comments'
      when query ~* 'drop trigger' or query ~* 'create trigger'                        then 'triggers'
      when query ~* 'add primary key' or query ~* 'add unique'
        or query ~* '^create (unique )?index .*on only'
        or query ~* '^alter index .*attach partition'                                  then 'pk_index'
      when query ~* '^insert into pgpm\.' or query ~* '^delete from pgpm\.'             then 'bookkeeping'
      else 'other'
    end as bucket,
    ms
  from s
),
-- computed from `bucketed`, not `s`: must exclude the same '(obtain-nested)' rows the display
-- does, or the denominator double-counts obtain's cost too (its wrapper row AND its nested rows)
-- and every percentage silently undercounts. Caught by a smoke run where percentages summed to
-- ~36% instead of ~100%.
total as (select sum(ms) as ms from bucketed where bucket <> '(obtain-nested)')
select bucket, round(sum(ms)::numeric, 3) as ms,
       round((100.0 * sum(ms) / nullif((select ms from total), 0))::numeric, 1) as pct
  from bucketed
 where bucket <> '(obtain-nested)'
 group by bucket
 order by ms desc;
SQL

# ---- build and run one fixture case ----
# args: label rows n_idx n_grants n_pol n_comments p_obtain
run_case() {
  local label="$1" rows="$2" n_idx="$3" n_grants="$4" n_pol="$5" n_comments="$6" p_obtain="$7"
  local DB="${DBPFX}_${label}"

  docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
  docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null
  q "create extension if not exists pg_stat_statements" >/dev/null

  {
    echo "create table public.tct_ref (id int primary key);"
    echo "insert into public.tct_ref select g from generate_series(1,100) g;"
    printf 'create table public.tct (id bigint primary key, ref_id int not null references public.tct_ref(id), v text'
    for i in $(seq 1 "$n_idx"); do printf ', col_i%d int default 0' "$i"; done
    printf ');\n'
    echo "insert into public.tct (id, ref_id, v) select g, ((g % 100) + 1), repeat('x', 40) from generate_series(1, $rows) g;"
    for i in $(seq 1 "$n_idx"); do echo "create index tct_idx_$i on public.tct (col_i$i);"; done
    echo "vacuum analyze public.tct;"
    for i in $(seq 1 "$n_grants"); do
      # roles are cluster-wide, not per-database (unlike everything else this fixture builds),
      # so a prior case's leftover role would collide here -- drop first.
      echo "drop role if exists tct_role_$i;"
      echo "create role tct_role_$i;"
      echo "grant select on public.tct to tct_role_$i;"
      echo "grant select (v) on public.tct to tct_role_$i;"
    done
    echo "alter table public.tct enable row level security;"
    echo "alter table public.tct force row level security;"
    for i in $(seq 1 "$n_pol"); do
      echo "create policy tct_pol_$i on public.tct for select using (true);"
    done
    echo "comment on table public.tct is 'bench fixture';"
    for i in $(seq 1 "$n_comments"); do
      echo "comment on column public.tct.col_i$i is 'bench column $i';"
    done
  } | docker exec -i "$C" psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 -f - >/dev/null

  q "select pg_stat_statements_reset()" >/dev/null
  qraw "call pgpm.transmute('public.tct'::regclass, 'id', $((rows * 2))::bigint, p_obtain => $p_obtain)" >/tmp/tct_bench_${label}.log 2>&1
  if [ $? -ne 0 ]; then
    echo "FATAL: transmute failed for case '$label':"
    cat /tmp/tct_bench_${label}.log
    exit 1
  fi

  echo
  echo "### $label (ROWS=$rows N_INDEXES=$n_idx N_GRANTS=$n_grants N_POLICIES=$n_pol N_COMMENTS=$n_comments P_OBTAIN=$p_obtain)"
  echo
  echo "| bucket | ms | % of phase-3 total |"
  echo "|---|---|---|"
  docker exec "$C" psql -U postgres -d "$DB" -qtA -F'|' -c "$BUCKET_SQL" | while IFS='|' read -r bucket ms pct; do
    [ -z "$bucket" ] && continue
    echo "| $bucket | $ms | $pct |"
  done

  docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  # roles are cluster-wide, not dropped with the database -- clean up so a container reused across
  # runs (or by a human operator afterward) is not left with grime.
  for i in $(seq 1 "$n_grants"); do
    docker exec "$C" psql -U postgres -qtA -c "drop role if exists tct_role_$i" >/dev/null 2>&1
  done
}

ROWS=${ROWS:-2000000}

echo "# Target 1: transmute phase-3 cutover timing"
echo "Container: $C   Install: $INSTALL"

run_case narrow_obtain0   "$ROWS" 10 10 5 10 0
run_case narrow_obtain30  "$ROWS" 10 10 5 10 30
run_case narrow_obtain100 "$ROWS" 10 10 5 10 100
run_case wide_obtain30    "$ROWS" 50 50 20 50 30

exit 0
