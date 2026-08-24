#!/usr/bin/env bash
# Regenerate docs/screenshot.png: the explainer hero, as linked from the README.
#
# WHY THIS EXISTS. This capture has been redone at least five times (see `git log --follow --
# docs/screenshot.png`) and the recipe lived only in a commit message, so each time it had to be
# reconstructed from the image's dimensions. The result drifted: the committed screenshot still read
# "refines the history" long after that step was renamed to `regrain`, because nobody could cheaply re-run
# the capture to notice.
#
# THE SHOT. 1280x840 viewport at 2x device pixel ratio, giving the 2560x1680 PNG the README expects. That
# viewport is chosen so the hero -- eyebrow, headline, lede, buttons, and the whole card fan -- lands above
# the fold with the nav visible and nothing clipped.
#
# TWO THINGS THAT WILL BITE YOU:
#
#   1. The card fan is JS-driven and animates 220 ms after load, over a 900 ms transition. A naive headless
#      screenshot catches a stack of invisible cards (they start at opacity 0). --virtual-time-budget lets
#      Chrome run that timeline to completion before capturing, so the fan is fully dealt.
#   2. The page pulls three families from Google Fonts. Capture with network access, or the display face
#      falls back and the headline sets differently from what visitors see.
#
# Usage: scripts/screenshot.sh [output-path]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT="${1:-docs/screenshot.png}"
PORT="${PORT:-8765}"

CHROME=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "$(command -v google-chrome 2>/dev/null)" \
         "$(command -v chromium 2>/dev/null)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CHROME="$c"; break; }
done
if [ -z "$CHROME" ]; then
  echo "ERROR: no Chrome/Chromium found. Install one, or pass its path via CHROME=..." >&2
  exit 1
fi

# Serve over http rather than file://: the page is fetched the way a visitor fetches it, and relative
# links (install.html) resolve. Killed on exit however this script ends.
python3 -m http.server "$PORT" --directory . >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT
sleep 1

# Chrome is bounded explicitly: with --headless=new it reliably WRITES the screenshot and then does not
# always exit on a page carrying timers and transitions, so waiting on it hangs. Wait for the file to
# appear, then end it. (macOS ships no coreutils `timeout`, hence doing this by hand.)
TMP="$(mktemp -d)"
rm -f "$OUT"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1280,840 --force-device-scale-factor=2 \
  --virtual-time-budget=4000 \
  --user-data-dir="$TMP" \
  --screenshot="$OUT" \
  "http://127.0.0.1:${PORT}/index.html" >/dev/null 2>&1 &
CPID=$!
for _ in $(seq 1 40); do
  [ -s "$OUT" ] && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1
done
sleep 1                                  # let the PNG finish flushing
kill "$CPID" 2>/dev/null
wait "$CPID" 2>/dev/null
rm -rf "$TMP"

if [ ! -f "$OUT" ]; then echo "ERROR: no screenshot written to $OUT" >&2; exit 1; fi

DIMS="$(python3 - "$OUT" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(33)
w, h = struct.unpack('>II', d[16:24])
print(f"{w}x{h}")
PY
)"
echo "wrote $OUT ($DIMS)"
[ "$DIMS" = "2560x1680" ] || { echo "ERROR: expected 2560x1680, got $DIMS" >&2; exit 1; }
