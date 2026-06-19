#!/usr/bin/env bash
# Build a self-contained single-file install bundle for clients that do not
# process psql metacommands -- e.g. the Supabase dashboard SQL editor. Paste the
# result in and run. Wrapped in BEGIN/COMMIT so a partial failure rolls back.
#
# pg_partition_magician's source (sql/pg_partition_magician.sql) is already a flat
# single file with no metacommands, so this is mostly a wrap. The `\ir`/`\i`
# inlining is kept for forward-compatibility if the source is ever split.
#
# Usage:   scripts/build_install_bundle.sh <src.sql> <out.sql>
# Example: scripts/build_install_bundle.sh sql/pg_partition_magician.sql dist/pg_partition_magician-bundle.sql
set -euo pipefail

SRC="${1:?usage: $0 <src.sql> <out.sql>}"
OUT="${2:?usage: $0 <src.sql> <out.sql>}"
[ -f "$SRC" ] || { echo "build_install_bundle: missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"

cat > "$OUT" <<EOF
-- pg_partition_magician install bundle (generated from $(basename "$SRC")).
-- Self-contained single-file install for clients that don't process psql
-- metacommands (e.g. the Supabase SQL editor). Wrapped in BEGIN/COMMIT.

BEGIN;

EOF

awk -v src_dir="$SRC_DIR" '
/^\\ir / { path = src_dir "/" $2; while ((getline line < path) > 0) print line; close(path); next }
/^\\i /  { path = $2;             while ((getline line < path) > 0) print line; close(path); next }
/^\\/    { printf "build_install_bundle: unhandled metacommand: %s\n", $0 > "/dev/stderr"; exit 2 }
{ print }
' "$SRC" >> "$OUT"

cat >> "$OUT" <<'EOF'

COMMIT;
EOF

echo "Built $OUT ($(wc -c < "$OUT") bytes)"
