#!/usr/bin/env bash
# Prove bench/sql/lockview_names.sql's managed_parent join is scoped by the parent's own schema,
# not just its bare relname (issue #392 review, finding 2). NOT wired to ./test.sh or any CI job --
# like bench/lock_timeout_pairing_demo.sh, this is a committed, runnable discrimination proof for a
# fix that would otherwise read as an unmotivated extra join condition to anyone who has not seen
# the duplicate-row defect it prevents. No eBPF needed: this is a plain SQL correctness check
# against a live database, not a lock-observation one.
#
# THE DEFECT
#
# pgpm.part's primary key is (parent_table, child_name), not (parent_table, nspname, child_name),
# so two managed parents that happen to share a bare relname in DIFFERENT schemas (public.orders
# and archive.orders, say) can each register a child with the SAME bare child_name -- nothing about
# a partition's own naming has ever had to be schema-unique, because two managed tables sharing a
# bare name in different schemas was never exercised before. The unscoped join
# `left join managed_parent mp on mp.child_name = bd.bare_name` then matches ONE child oid against
# BOTH parents' rows in pgpm.part, emitting duplicate CSV rows for that oid with different `parent`
# labels; bench/plot_lock_view.py's `_read_names` does `out[oid] = Relation(...)`, so whichever
# duplicate comes LAST in the CSV wins, and locks fold onto the wrong parent nondeterministically.
#
# THE FIX scopes the join by the parent's own schema as well as its bare name
# (bench/sql/lockview_names.sql), on the invariant that a partition lives in its parent's own
# schema.
#
# WHAT THIS SCRIPT DOES
#
#   1. Creates a second schema alongside `public`, each holding a table named `orders` and a child
#      table named `orders_p1` -- deliberately the SAME bare names in both schemas.
#   2. Hand-inserts two pgpm.part rows, one per schema, both with child_name = 'orders_p1'. The
#      real-world route to this collision is two independently-transmuted tables that happen to
#      share a bare relname; hand-inserting the catalog row reproduces the exact same collision
#      without needing a full transmute() to coincidentally produce matching child suffixes.
#   3. Runs the EXACT query bench/lock_view.sh's names_snapshot() runs
#      (bench/sql/lockview_names.sql), via the same -f path the harness uses, against the live
#      database.
#   4. Asserts each child oid resolves to exactly ONE CSV row, and that row's parent names ITS OWN
#      schema's table, never the other schema's.
#
# WHAT TO LOOK FOR
#
#   All four PASS against the fixed query. Reverting bench/sql/lockview_names.sql's managed_parent
#   join and the partition-kind `exists` check to bare-name-only (see the file's own history) turns
#   the row-count checks into "got 2, want 1" -- both child oids get a duplicate CSV row, one per
#   colliding parent, which is the defect itself made visible rather than inferred.
#
# USAGE
#
#   bench/lock_view_names_scope_demo.sh <container> <db>
#   bench/lock_view_names_scope_demo.sh pgpm_test-17 lv_scope
#
# PREREQUISITES
#
#   Any pg-base-derived compose service, up and healthy (e.g. `docker compose --profile pg17 up
#   -d`). <db> is created and dropped by this script.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-62s %s\n' "$1" "$2"
  else printf 'FAIL  %-62s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -d "$DB" -q -f /repo/pgpm_core/install.sql >/dev/null 2>&1

q "create schema if not exists lv_scope_b" >/dev/null
q "create table public.orders (id int)" >/dev/null
q "create table public.orders_p1 (id int)" >/dev/null
q "create table lv_scope_b.orders (id int)" >/dev/null
q "create table lv_scope_b.orders_p1 (id int)" >/dev/null
q "insert into pgpm.part (parent_table, child_name, lo, hi)
   values ('public.orders'::regclass, 'orders_p1', '0', '10')" >/dev/null
q "insert into pgpm.part (parent_table, child_name, lo, hi)
   values ('lv_scope_b.orders'::regclass, 'orders_p1', '0', '10')" >/dev/null

PUB_OID=$(q "select 'public.orders_p1'::regclass::oid")
ARC_OID=$(q "select 'lv_scope_b.orders_p1'::regclass::oid")
[ -n "$PUB_OID" ] && [ -n "$ARC_OID" ] || { echo "error: fixture tables did not resolve to oids" >&2; exit 1; }

CSV=$(docker exec "$C" psql -U postgres -d "$DB" -qtA -F, -f /repo/bench/sql/lockview_names.sql)

pub_rows=$(printf '%s\n' "$CSV" | awk -F, -v oid="$PUB_OID" '$1==oid' | wc -l | tr -d ' ')
arc_rows=$(printf '%s\n' "$CSV" | awk -F, -v oid="$ARC_OID" '$1==oid' | wc -l | tr -d ' ')
pub_parent=$(printf '%s\n' "$CSV" | awk -F, -v oid="$PUB_OID" '$1==oid {print $3}' | tail -1)
arc_parent=$(printf '%s\n' "$CSV" | awk -F, -v oid="$ARC_OID" '$1==oid {print $3}' | tail -1)

check "public.orders_p1 resolves to exactly one CSV row" "$pub_rows" "1"
check "lv_scope_b.orders_p1 resolves to exactly one CSV row" "$arc_rows" "1"
check "public.orders_p1 folds onto its own schema's parent" "$pub_parent" "public.orders"
check "lv_scope_b.orders_p1 folds onto its own schema's parent" "$arc_parent" "lv_scope_b.orders"

docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1

if [ "$fail" -ne 0 ]; then echo "lock_view_names_scope_demo: FAIL"; exit 1; fi
echo "lock_view_names_scope_demo: PASS"
