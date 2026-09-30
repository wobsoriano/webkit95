#!/bin/bash
# Native UI QA of build/webkit95.app with real input: keyboard shortcuts through the macOS menu
# bar, clicks on the Win95 menu bar, toolbar, title bar, size grip and splitter, a sign in popup
# opened by a real click, JS dialog keys, find, F5, text size keys and the Win95 context menu.
#
# Real input takes the screen, so this script only acts when it is safe:
#   - it waits until the user has been idle for QA_IDLE_NEED seconds (default 60, at most
#     QA_IDLE_MAX seconds, default 900) and aborts the moment they touch the keyboard or mouse;
#   - it opens the app by bundle id (dev.webkit95.browser, never by name: `agent-device open Loki`
#     once attached to the user's Google Chrome) in agent-device session webkit95-qa, and checks
#     the snapshot's App: line before printing or acting on anything;
#   - before every click, drag or key it asks System Events (read only) that webkit95 is frontmost,
#     and before every click that the point lies inside webkit95's window and that the frontmost
#     window under it is webkit95's (never a system prompt or another app's window);
#   - clicks go through scripts/click.swift (HID level, screen points) and keys through
#     scripts/key.swift (posted to webkit95's pid only), because agent-device's primary click never
#     reached custom controls on this Mac;
#   - a trap closes the agent-device session and quits the test app on any exit.
# Every check prints ok or NOT VERIFIED with the reason. Temp dirs for favorites and downloads,
# the fake agent. Usage: scripts/device-qa.sh (QA_SKIP_BUILD=1 reuses build/webkit95.app).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="dev.webkit95.browser"
ADS="webkit95-qa"
CTL_PORT=9398; WEB_PORT=8799; AUTH_PORT=8800
BASE="http://127.0.0.1:$WEB_PORT"; AUTH="http://localhost:$AUTH_PORT"
IDLE_NEED="${QA_IDLE_NEED:-60}"; IDLE_MAX="${QA_IDLE_MAX:-900}"
TOKEN_FILE="$ROOT/build/control-device-qa.token"
LOG="$ROOT/build/device-qa.log"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/webkit95-qa.XXXXXX")"
mkdir -p "$SCRATCH/downloads" "$SCRATCH/support"

CHECKS=(
  "open by bundle id attaches to the test webkit95"
  "Cmd+L focuses the address field and typing a URL with Return loads it"
  "Cmd+N opens a new window through the macOS menu bar"
  "a real click on View opens the Win95 menu, Down and Return run its first row"
  "Escape closes an open Win95 menu"
  "a real click on the Home toolbar button loads the start page"
  "a real click on Sign in opens the popup window and its window.close() closes it"
  "Tab and Return answer a JS confirm from the keyboard"
  "Cmd+F, typing and Return find the text"
  "F5 reloads the page"
  "Cmd+plus and Cmd+0 change the text size"
  "dragging the title bar moves the window"
  "double click on the title bar maximizes and restores"
  "dragging the size grip resizes the window"
  "dragging the splitter resizes the Explorer Bar"
  "a real right click shows the Win95 context menu and no macOS menu"
  "the title bar close button closes a window"
  "the macOS menu bar has the webkit95 app menu with About and Quit (read only)"
)
REPORTED="|"
ok() { printf 'ok            %s\n' "$1"; REPORTED="$REPORTED$1|"; }
nv() { printf 'NOT VERIFIED  %s (%s)\n' "$1" "$2"; REPORTED="$REPORTED$1|"; }
abort() {
  for c in "${CHECKS[@]}"; do case "$REPORTED" in *"|$c|"*) ;; *) nv "$c" "aborted: $1" ;; esac; done
  exit 3
}

ctl() { WEBKIT95_CONTROL_PORT="$CTL_PORT" WEBKIT95_CONTROL_TOKEN_FILE="$TOKEN_FILE" "$ROOT/scripts/ctl.sh" "$@"; }
st() { ctl state | python3 -c "import json,sys; s=json.load(sys.stdin); w=s['windows']; print($1)" 2>/dev/null; }
wait_for() { local t=0; while [ "$t" -lt $(( ${2:-10} * 4 )) ]; do [ "$(st "$1")" = True ] && return 0; sleep 0.25; t=$((t + 1)); done; return 1; }
# "x y w h" of a part from the app's own frame command (screen points, top left origin).
frame() { ctl "${2:-@0}" frame "$1" | python3 -c "import json,sys; f=json.load(sys.stdin)['frame']; print(' '.join(str(int(round(v))) for v in f))" 2>/dev/null; }
centre() { set -- $1; echo "$(( $1 + $3 / 2 )) $(( $2 + $4 / 2 ))"; }
LAST_ACTION=$(date +%s)
key() { guard_front; timeout 60 swift "$ROOT/scripts/key.swift" "$PID" key "$@" >/dev/null; LAST_ACTION=$(date +%s); sleep 0.5; }
typ() { guard_front; timeout 60 swift "$ROOT/scripts/key.swift" "$PID" type "$@" >/dev/null; LAST_ACTION=$(date +%s); sleep 0.3; }
click() { guard_point "$2" "$3" "${4:-@0}"; timeout 60 swift "$ROOT/scripts/click.swift" "$1" "$2" "$3" >/dev/null; LAST_ACTION=$(date +%s); sleep 0.6; }
drag() { guard_point "$1" "$2" "${5:-@0}"; guard_point "$3" "$4" "${5:-@0}"; timeout 60 swift "$ROOT/scripts/click.swift" drag "$1" "$2" "$3" "$4" >/dev/null; LAST_ACTION=$(date +%s); sleep 0.8; }

launch() {
  WEBKIT95_CONTROL=1 WEBKIT95_CONTROL_PORT="$CTL_PORT" WEBKIT95_CONTROL_TOKEN_FILE="$TOKEN_FILE" WEBKIT95_BACKGROUND=1 \
    WEBKIT95_SUPPORT_DIR="$SCRATCH/support" WEBKIT95_DOWNLOAD_DIR="$SCRATCH/downloads" \
    WEBKIT95_AGENT_COMMAND="python3 $ROOT/Tests/Webkit95AgentTests/Resources/fake_agent.py" \
    WEBKIT95_LOG="$LOG" timeout 1800 "$ROOT/scripts/run.sh" &
  for _ in $(seq 1 80); do ctl state 2>/dev/null | grep -q windows && break; sleep 0.25; done
  PID="$(pgrep -f "$ROOT/build/webkit95.app/Contents/MacOS/webkit95$" | head -1)"
}
quit_app() {
  ctl quit >/dev/null 2>&1
  for _ in $(seq 1 40); do pgrep -f "$ROOT/build/webkit95.app/Contents/MacOS/webkit95" >/dev/null || return 0; sleep 0.25; done
  pkill -9 -f "$ROOT/build/webkit95.app/Contents/MacOS/webkit95" 2>/dev/null
}
cleanup() {
  timeout 30 agent-device close --session "$ADS" --platform macos >/dev/null 2>&1
  quit_app
  { kill "$SERVER" "$AUTH_SERVER" && wait "$SERVER" "$AUTH_SERVER"; } 2>/dev/null
  rm -rf "$SCRATCH"
}

# ---- safety gates -------------------------------------------------------------------------------

idle_s() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
# Our own input resets the idle clock too, so idle only has to cover the time since our last action.
user_idle() {
  [ "$("$ROOT/scripts/screen-locked.sh")" = 0 ] || return 1
  [ "$(idle_s)" -ge $(( $(date +%s) - LAST_ACTION - 2 )) ]
}
# "bundle pid" of the frontmost app; com.apple.loginwindow while the screen saver or lock screen shows.
frontmost() {
  timeout 10 osascript -e 'tell application "System Events" to set p to first application process whose frontmost is true' \
    -e 'tell application "System Events" to return (bundle identifier of p) & " " & (unix id of p)' 2>/dev/null
}
guard_front() {
  user_idle || abort "user activity detected"
  local front; front="$(frontmost)"
  [ "$front" = "$BUNDLE $PID" ] || abort "webkit95 is not frontmost (frontmost: ${front% *})"
}
# The next action hits screen point $1,$2; it must lie inside the target window ($3, default @0).
guard_point() {
  guard_front
  local b; b="$(frame window "${3:-@0}")"
  set -- "$1" "$2" $b
  [ $# = 6 ] || abort "no window frame from webkit95"
  python3 -c "import sys; x,y,wx,wy,ww,wh=map(float,sys.argv[1:]); sys.exit(0 if wx+1<=x<=wx+ww-1 and wy+1<=y<=wy+wh-1 else 1)" "$@" ||
    abort "target $1,$2 is outside webkit95's window $3,$4 $5x$6"
  # Nothing of another app, a system prompt included, may cover the point.
  local top; top="$(timeout 60 swift "$ROOT/scripts/topmost-at.swift" "$1" "$2")"
  [ "${top% *}" = webkit95 ] || abort "the frontmost window at $1,$2 belongs to ${top% *}, not webkit95"
}
# After an open: the text snapshot's App: line must name our bundle; nothing of it is printed.
app_line_ok() {
  local text; text="$(timeout 240 agent-device snapshot --session "$ADS" --platform macos 2>&1)"
  [ "$(printf '%s\n' "$text" | grep -m1 '^App:' | tr -d ' ')" = "App:$BUNDLE" ]
}

# ---- run ----------------------------------------------------------------------------------------

command -v agent-device >/dev/null || { for c in "${CHECKS[@]}"; do nv "$c" "agent-device is not installed"; done; exit 3; }
if pgrep -f "webkit95.app/Contents/MacOS/webkit95" >/dev/null; then
  for c in "${CHECKS[@]}"; do nv "$c" "another webkit95 is running; quit it so bundle id $BUNDLE names only the test instance"; done
  exit 3
fi
if [ -z "${QA_SKIP_BUILD:-}" ]; then
  timeout 900 "$ROOT/scripts/bundle.sh" > "$ROOT/build/device-qa-build.log" 2>&1 || { echo "FAIL  build (see build/device-qa-build.log)"; exit 1; }
fi
python3 "$ROOT/scripts/testserver.py" "$WEB_PORT" >/dev/null 2>&1 &
SERVER=$!
python3 "$ROOT/scripts/testserver.py" "$AUTH_PORT" >/dev/null 2>&1 &
AUTH_SERVER=$!
trap cleanup EXIT
launch
[ -n "${PID:-}" ] || abort "webkit95 did not start"

# Everything that needs no screen happens before the gate, with the app in the background.
ctl resize 900x680 >/dev/null
ctl navigate "$BASE/second.html" >/dev/null
wait_for 'w[0]["title"]=="Second Page" and not w[0]["loading"]' 15

echo "waiting for ${IDLE_NEED}s of user idle (at most ${IDLE_MAX}s) before taking the screen"
if ! "$ROOT/scripts/wait-idle.sh" "$IDLE_NEED" "$IDLE_MAX"; then
  for c in "${CHECKS[@]}"; do nv "$c" "the user was never idle for ${IDLE_NEED}s within ${IDLE_MAX}s; rerun scripts/device-qa.sh when away"; done
  exit 3
fi
LAST_ACTION=$(date +%s)
user_idle || abort "user activity detected"
timeout 60 agent-device open "$BUNDLE" --session "$ADS" --platform macos >/dev/null 2>&1
LAST_ACTION=$(date +%s)
sleep 1.5
app_line_ok || abort "the snapshot's App line is not $BUNDLE; its content was not printed"
guard_front
ok "${CHECKS[0]}"
# The agent-device session keeps macOS automation mode on, whose AutomationModeUI window covers
# the screen and made every click gate refuse. The session has done its job (open by bundle id,
# App line verified), so it ends here; the frontmost and topmost gates cover the rest.
timeout 30 agent-device close --session "$ADS" --platform macos >/dev/null 2>&1
sleep 1
guard_front

# The only moment webkit95 is the active app: capture its window with the active title bar.
mkdir -p "$ROOT/build/shots"
WID="$(timeout 60 swift "$ROOT/scripts/winid.swift" webkit95 | head -1 | cut -d' ' -f1)"
if [ -n "$WID" ] && screencapture -x -o -l "$WID" "$ROOT/build/shots/active-window.png"; then
  timeout 60 swift "$ROOT/scripts/onex.swift" "$ROOT/build/shots/active-window.png" "$ROOT/build/shots/active-window-1x.png" >/dev/null
fi

C="${CHECKS[1]}"
key l cmd
typ "127.0.0.1:$WEB_PORT/find.html"
key return
if wait_for 'w[0]["title"]=="Find Test" and not w[0]["loading"]' 10; then ok "$C"; else nv "$C" "title $(st 'w[0]["title"]')"; fi

C="${CHECKS[2]}"
key n cmd
if wait_for 'len(w)==2 and w[1]["title"]=="Welcome to webkit95"' 8; then ok "$C"; else nv "$C" "windows $(st 'len(w)')"; fi
ctl @1 close-window >/dev/null; wait_for 'len(w)==1' 5; sleep 0.5

C="${CHECKS[3]}"
read -r mx my <<< "$(centre "$(frame menu:2)")"
click click "$mx" "$my"
if wait_for 'w[0]["menu"]=="menu:View:1"' 3; then
  key down; key return
  if wait_for 'not w[0]["toolbar"]' 3; then ok "$C"; else nv "$C" "toolbar $(st 'w[0]["toolbar"]')"; fi
  ctl press view.toolbar >/dev/null
else nv "$C" "menu $(st 'w[0]["menu"]')"; fi

C="${CHECKS[4]}"
read -r mx my <<< "$(centre "$(frame menu:0)")"
click click "$mx" "$my"
if wait_for 'w[0]["menu"]=="menu:File:1"' 3; then
  key escape
  if wait_for 'w[0]["menu"] is None' 3; then ok "$C"; else nv "$C" "menu $(st 'w[0]["menu"]')"; fi
else nv "$C" "no File menu: $(st 'w[0]["menu"]')"; fi

C="${CHECKS[5]}"
read -r hx hy <<< "$(centre "$(frame toolbar:go.home)")"
click click "$hx" "$hy"
if wait_for 'w[0]["title"]=="Welcome to webkit95"' 8; then ok "$C"; else nv "$C" "title $(st 'w[0]["title"]')"; fi

C="${CHECKS[6]}"
ctl navigate "$BASE/oauth.html?auth=$AUTH&close=1500" >/dev/null
wait_for 'w[0]["title"]=="OAuth Opener" and not w[0]["loading"]' 10
read -r sx sy <<< "$(centre "$(frame element:#signin)")"
click click "$sx" "$sy"
if wait_for 'len(w)==2' 5; then
  if wait_for 'len(w)==1 and w[0]["title"]=="Signed in"' 8; then ok "$C"; else nv "$C" "after close: $(st '[x["title"] for x in w]')"; fi
else nv "$C" "no popup window: $(st '[x["title"] for x in w]')"; fi

C="${CHECKS[7]}"
ctl navigate "$BASE/dialog.html?auto=confirm" >/dev/null
if wait_for 'len(w[0]["dialogs"])==1' 8; then
  key tab; key return
  if wait_for 'w[0]["title"]=="Dialog confirm:false"' 5; then ok "$C"; else nv "$C" "title $(st 'w[0]["title"]')"; fi
else nv "$C" "no confirm dialog"; fi

C="${CHECKS[8]}"
ctl navigate "$BASE/find.html" >/dev/null
wait_for 'w[0]["title"]=="Find Test" and not w[0]["loading"]' 10
key f cmd
if wait_for 'any(d["kind"]=="find" for d in w[0]["dialogs"])' 3; then
  typ wk95needle; key return
  if wait_for 'w[0]["find"]["found"]==True' 5; then ok "$C"; else nv "$C" "find $(st 'w[0]["find"]')"; fi
  key escape
else nv "$C" "no Find dialog"; fi

C="${CHECKS[9]}"
ctl js "window.__qa = 1" >/dev/null
key f5
if wait_for 'not w[0]["loading"]' 8 && [ "$(ctl js 'window.__qa === undefined' | grep -c true)" = 1 ]; then ok "$C"; else nv "$C" "the page kept its marker"; fi

C="${CHECKS[10]}"
key = cmd
if wait_for 'w[0]["textSize"]=="Larger"' 3; then
  key 0 cmd
  if wait_for 'w[0]["textSize"]=="Medium"' 3; then ok "$C"; else nv "$C" "size $(st 'w[0]["textSize"]')"; fi
else nv "$C" "size $(st 'w[0]["textSize"]')"; fi

C="${CHECKS[11]}"
BEFORE="$(frame window)"
read -r tx ty tw _ <<< "$(frame titlebar)"
fx=$(( tx + tw / 2 )); fy=$(( ty + 8 ))
drag "$fx" "$fy" $(( fx - 40 )) $(( fy + 30 ))
AFTER="$(frame window)"
if [ "$AFTER" != "$BEFORE" ]; then ok "$C ($BEFORE -> $AFTER)"; else nv "$C" "window stayed at $BEFORE"; fi

C="${CHECKS[12]}"
read -r tx ty tw _ <<< "$(frame titlebar)"
click double $(( tx + tw / 2 )) $(( ty + 8 ))
MAX="$(frame window)"
read -r tx ty tw _ <<< "$(frame titlebar)"
click double $(( tx + tw / 2 )) $(( ty + 8 ))
RESTORED="$(frame window)"
if [ "$MAX" != "$AFTER" ] && [ "$RESTORED" = "$AFTER" ]; then ok "$C"; else nv "$C" "$AFTER -> $MAX -> $RESTORED"; fi

C="${CHECKS[13]}"
read -r gx gy _ _ <<< "$(frame grip)"
BEFORE="$(frame window)"
drag $(( gx + 6 )) $(( gy + 6 )) $(( gx - 60 )) $(( gy - 40 ))
AFTER="$(frame window)"
if [ "$(echo "$AFTER" | cut -d' ' -f3)" -lt "$(echo "$BEFORE" | cut -d' ' -f3)" ]; then ok "$C ($BEFORE -> $AFTER)"; else nv "$C" "$BEFORE -> $AFTER"; fi

C="${CHECKS[14]}"
ctl press view.assistant >/dev/null
if wait_for 'w[0]["assistantOpen"]' 5; then
  W0="$(st 'w[0]["assistantWidth"]')"
  read -r px py pw ph <<< "$(frame splitter)"
  drag $(( px + pw / 2 )) $(( py + ph / 2 )) $(( px + pw / 2 + 50 )) $(( py + ph / 2 ))
  W1="$(st 'w[0]["assistantWidth"]')"
  if [ "$W0" != "$W1" ]; then ok "$C ($W0 -> $W1)"; else nv "$C" "width stayed $W0"; fi
  ctl press view.assistant >/dev/null
else nv "$C" "the Explorer Bar did not open"; fi

C="${CHECKS[15]}"
ctl navigate "$BASE/" >/dev/null
wait_for 'w[0]["title"]=="webkit95 Smoke" and not w[0]["loading"]' 10
read -r lx ly <<< "$(centre "$(frame element:#second)")"
click right "$lx" "$ly"
if wait_for 'w[0]["menu"]=="menu:popup:1"' 3 && [ "$(timeout 60 swift "$ROOT/scripts/popup-windows.swift" webkit95)" = 0 ]; then ok "$C"
else nv "$C" "menu $(st 'w[0]["menu"]'), popup windows $(timeout 60 swift "$ROOT/scripts/popup-windows.swift" webkit95)"; fi
key escape

C="${CHECKS[16]}"
ctl press file.newWindow >/dev/null
if wait_for 'len(w)==2' 5; then
  sleep 0.8
  guard_front
  read -r cx cy <<< "$(centre "$(frame close @1)")"
  click click "$cx" "$cy" @1
  if wait_for 'len(w)==1' 5; then ok "$C"; else nv "$C" "windows $(st 'len(w)')"; fi
else nv "$C" "no second window"; fi

C="${CHECKS[17]}"
guard_front
ITEMS="$(timeout 60 swift "$ROOT/scripts/ax.swift" "$PID" menu-items webkit95 2>/dev/null)"
if printf '%s\n' "$ITEMS" | grep -q "^About webkit95" && printf '%s\n' "$ITEMS" | grep -q "^Quit webkit95"; then ok "$C"
else nv "$C" "items: $(printf '%s' "$ITEMS" | cut -f1 | paste -sd'|' -)"; fi
