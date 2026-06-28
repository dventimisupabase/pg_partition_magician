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
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"

# Header written before the minifier runs (which strips `--` lines).
cat > "$OUT" <<'HDR'
-- pg_partition_magician -- dbdev/TLE package (minified single file).
HDR

awk -v src_dir="$SRC_DIR" '
function emit_line(line,   stripped) {
    stripped = line
    sub(/^[ \t]+/, "", stripped); sub(/[ \t]+$/, "", stripped)
    if (stripped == "") return
    if (stripped ~ /^--/) return
    if (in_comment_on) { if (stripped ~ /;[ \t]*$/) in_comment_on = 0; return }
    if (stripped ~ /^(COMMENT ON|comment on)[ \t]/) {
        if (stripped !~ /;[ \t]*$/) in_comment_on = 1
        return
    }
    # collapse internal whitespace only on lines with no quoting (safe for SQL/plpgsql)
    if (stripped !~ /[\x27"]|\$\$|\$[A-Za-z_]+\$/) gsub(/[ \t]+/, " ", stripped)
    print stripped
}
/^\\ir / { path = src_dir "/" $2; while ((getline line < path) > 0) emit_line(line); close(path); next }
/^\\i /  { path = $2;             while ((getline line < path) > 0) emit_line(line); close(path); next }
{ emit_line($0) }
' "$SRC" >> "$OUT"

SIZE=$(wc -c < "$OUT")
echo "Built $OUT (${SIZE} bytes)"
if [ "$SIZE" -gt 250000 ]; then
  echo "ERROR: $OUT is ${SIZE} chars, exceeds the 250,000-char dbdev limit" >&2
  exit 1
fi
