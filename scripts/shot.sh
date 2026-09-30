#!/bin/bash
# Captures one webkit95 window of a running dev instance into build/shots/<name>.png (2x) and
# <name>-1x.png (exact 1x). The window is ordered front WITHOUT activating the app, so a person's
# typing stays where it was, and ordered back afterwards. It waits for a short idle pause first,
# because a window that pops up under someone's click gets clicked.
# Usage: scripts/shot.sh <name> [front command, default "front"] [settle seconds, default 1]
# Env: WEBKIT95_CONTROL_PORT, WEBKIT95_CONTROL_TOKEN_FILE (as for ctl.sh), SHOT_IDLE (default 8).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/shots"
mkdir -p "$OUT"
NAME="$1"; FRONT="${2:-front}"; SETTLE="${3:-1}"
"$ROOT/scripts/wait-idle.sh" "${SHOT_IDLE:-8}" 300 >/dev/null
"$ROOT/scripts/ctl.sh" $FRONT >/dev/null
sleep "$SETTLE"
TITLE_FILTER="${SHOT_TITLE:-}"
ID="$(timeout 60 swift "$ROOT/scripts/winid.swift" webkit95 | { if [ -n "$TITLE_FILTER" ]; then grep -F -- "$TITLE_FILTER"; else cat; fi; } | head -1 | cut -d' ' -f1)"
if [ -z "$ID" ]; then echo "no window for $NAME"; exit 1; fi
screencapture -x -o -l "$ID" "$OUT/$NAME.png"
"$ROOT/scripts/ctl.sh" back >/dev/null
timeout 60 swift "$ROOT/scripts/onex.swift" "$OUT/$NAME.png" "$OUT/$NAME-1x.png" >/dev/null && echo "$OUT/$NAME-1x.png"
