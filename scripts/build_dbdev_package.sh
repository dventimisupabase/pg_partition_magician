#!/usr/bin/env bash
# Build a minified single-file package for dbdev / Trusted Language Extension
# publishing (CREATE EXTENSION). dbdev enforces a 250,000-char cap, so full-line
# `--` comments, blank lines, and COMMENT ON statements are stripped. Dollar-quoted
# bodies and inline quoted literals are preserved verbatim.
#
# Usage:   scripts/build_dbdev_package.sh <src.sql> <out.sql>
# Example: scripts/build_dbdev_package.sh pgpm_core/install.sql dist/pg_partition_magician--0.1.0.sql
set -euo pipefail

SRC="${1:?usage: $0 <src.sql> <out.sql>}"
OUT="${2:?usage: $0 <src.sql> <out.sql>}"
[ -f "$SRC" ] || { echo "build_dbdev_package: missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Header written before the minifier runs (which strips `--` lines).
cat > "$OUT" <<'HDR'
-- pg_partition_magician -- dbdev/TLE package (minified single file).
HDR

# The minifier is scripts/minify_sql.py, not the awk that used to live here: every decision it makes
# (drop a blank line, drop a `--` line, drop a COMMENT ON, collapse whitespace) depends on whether
# the line sits inside a string literal, and the awk judged each one from the line's own leading
# characters with no way to know (issue #410). It carries its own `--selftest`.
python3 "$HERE/minify_sql.py" "$SRC" >> "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built $OUT (${SIZE} bytes)"
if [ "$SIZE" -gt 250000 ]; then
  echo "ERROR: $OUT is ${SIZE} chars, exceeds the 250,000-char dbdev limit" >&2
  exit 1
fi
