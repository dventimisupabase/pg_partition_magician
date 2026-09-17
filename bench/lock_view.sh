#!/usr/bin/env bash
# Render a lock sequence for human review (issue #392). NOT a guard: it asserts nothing about pgpm's
# behaviour and blocks no merge. bench/lock_trace.sh is the guard; this is the picture.
#
# Usage: lock_view.sh <container> <db> <relations> <sql> [run-name]
#   lock_view.sh pgpm_test-locktrace mydb 'public.mg_ret,public.ml' "call pgpm.maintain_all()"
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; RELS="${3:?relations}"; SQL="${4:?sql}"
RUN="${5:-run}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results/lockview-$RUN-$(date +%Y%m%d-%H%M%S)"
EVENTS=/tmp/pgpm_lock_view.jsonl
PLOG=/tmp/pgpm_lock_view.log

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }

# Asserted up front so that losing it is legible, rather than a BCC compile error a hundred lines
# into a log.
if ! docker exec "$C" python3 -c 'import bcc' 2>/dev/null; then
  echo "error: $C has no bcc. Start the locktrace service:" >&2
  echo "  docker compose --profile locktrace up -d" >&2
  exit 1
fi

mkdir -p "$OUT"
OIDS=$(q "select string_agg(c.oid::text, ',') from unnest(string_to_array('$RELS', ','))
          r join pg_class c on c.oid = trim(r)::regclass")
[ -n "$OIDS" ] || { echo "error: none of '$RELS' resolved" >&2; exit 1; }

# The name map, snapshotted DURING the window. The three folds are SQL joins because that is where
# they belong: index to its table, toast to its table, partition to its managed parent. Resolving
# any of this afterwards fails for the relations most worth seeing, since retain drops them.
#
# Folding this to a base table takes up to two hops, not one, and a real retain-drop capture
# exercises every depth: a plain index or toast on a normal table is one hop (index -> its
# table); a partition's OWN index or toast is two hops (index -> the partition -> the
# partition's managed parent, via pgpm.part); and an index ON a partition's toast table is
# three hops (index -> toast -> the partition -> the parent). base1/base2 below apply the
# "index -> indrelid, else toast -> its owning table, else itself" step twice, which is enough
# to walk index-on-toast-of-partition down to the real base table (a toast table cannot itself
# be indexed-and-toasted further, so two applications always reach a fixed point); the
# managed_parent join then folds that base table's own name if pgpm.part says it is a child.
# A single-hop version of this was tried first and produced 131 rows on a real 31-partition
# retain-drop capture instead of the roughly-ten the design predicts: every dropped partition's
# own index and toast table (and the toast's own index) sat in one-off rows instead of joining
# the partition's.
names_snapshot() {
  docker exec "$C" psql -U postgres -d "$DB" -qtA -F, -c "
    with base1 as (
      select c.oid,
             coalesce(i.indrelid,
                      (select t.oid from pg_class t where t.reltoastrelid = c.oid),
                      c.oid) as b
        from pg_class c
        left join pg_index i on i.indexrelid = c.oid
       where c.oid >= 16384
    ),
    base2 as (
      select b1.oid,
             coalesce(i2.indrelid,
                      (select t2.oid from pg_class t2 where t2.reltoastrelid = b1.b),
                      b1.b) as b
        from base1 b1
        left join pg_index i2 on i2.indexrelid = b1.b
    ),
    based as (
      select b2.oid, pc.relname as bare_name,
             pn.nspname || '.' || pc.relname as qname
        from base2 b2
        join pg_class pc on pc.oid = b2.b
        join pg_namespace pn on pn.oid = pc.relnamespace
    ),
    managed_parent as (
      select p.child_name,
             pn.nspname || '.' || pc.relname as qname
        from pgpm.part p
        join pg_class pc on pc.oid = p.parent_table
        join pg_namespace pn on pn.oid = pc.relnamespace
    )
    select c.oid,
           n.nspname || '.' || c.relname,
           coalesce(mp.qname, bd.qname, '') as parent,
           case when c.relkind = 'i' then 'index'
                when n.nspname = 'pg_toast' then 'toast'
                when exists (select 1 from pgpm.part p where p.child_name = c.relname)
                  then 'partition'
                else 'other' end
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      left join based bd on bd.oid = c.oid
      left join managed_parent mp on mp.child_name = bd.bare_name
     where c.oid >= 16384
     order by c.oid"
}

names_snapshot > "$OUT/names.before.csv"

docker exec "$C" sh -c "rm -f $EVENTS $PLOG"
docker exec -d "$C" sh -c "python3 /repo/bench/lock_view.py $OIDS $EVENTS > $PLOG 2>&1"

# Gate on READY, never on anything printed earlier: it is the only line that means the uprobes are
# attached AND the ring buffer is open.
ready=false
for _ in $(seq 1 90); do
  if docker exec "$C" grep -q '^READY' "$PLOG" 2>/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "error: probe never became READY" >&2
  docker exec "$C" cat "$PLOG" >&2
  docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
  exit 1
fi

# The probe's bpf_ktime_get_ns() and the host's CLOCK_MONOTONIC are the SAME clock domain (same
# kernel), verified on the design spike. Clocks cross the container boundary; pids do not.
T_BEGIN=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
# Kept and checked, not discarded: a failed or partially-executed traced statement still lets
# the capture and render proceed (a near-empty capture usually trips the "empty"/"strong"
# refusal downstream), but that refusal reads as "the probe saw nothing" when the real cause
# was the SQL itself. Warning here, with the real error alongside the capture, means a wrong
# picture never has to be debugged as though it were a probe defect.
if ! docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$SQL" >/dev/null 2>"$OUT/sql.stderr"; then
  echo "warning: the traced statement exited non-zero; see $OUT/sql.stderr" >&2
  echo "         the capture below may be empty or partial for that reason, not because the probe failed" >&2
fi
T_END=$(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')

# SIGINT then WAIT: the drop count is written on the way out, and reading early truncates the very
# record that says whether anything was lost.
docker exec "$C" pkill -INT -f lock_view.py >/dev/null 2>&1
probe_exited=false
for _ in $(seq 1 30); do
  docker exec "$C" pgrep -f lock_view.py >/dev/null 2>&1 || { probe_exited=true; break; }
  sleep 1
done
if [ "$probe_exited" != true ]; then
  echo "warning: the probe did not exit within 30s of SIGINT" >&2
  echo "         the capture may be truncated and the drop count may be missing; expect the" >&2
  echo "         downstream 'drain' refusal if so" >&2
fi

names_snapshot > "$OUT/names.after.csv"
docker cp "$C:$EVENTS" "$OUT/events.jsonl" >/dev/null

python3 - "$OUT" "$RUN" "$SQL" "$RELS" "$OIDS" "$T_BEGIN" "$T_END" <<'PY'
import json, subprocess, sys
out, run, sql, rels, oids, t0, t1 = sys.argv[1:8]
sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                     capture_output=True, text=True).stdout.strip()
open(f"{out}/meta.json", "w").write(json.dumps({
    "run": run, "sql": sql, "enlist": rels.split(","),
    "enlist_oids": [int(o) for o in oids.split(",")],
    "t_begin": int(t0), "t_end": int(t1), "git_sha": sha,
}, indent=2) + "\n")
PY

# plot_lock_view.py imports matplotlib, which the system python3 does not have (PEP 668 blocks
# `pip install matplotlib` there); run it under the venv this repo keeps for exactly this
# (Ruling 8a), never the system interpreter.
"$ROOT/.venv-lockview/bin/python" "$ROOT/bench/plot_lock_view.py" "$OUT" || exit 1
echo "wrote $OUT/lock-view.png and .svg"
