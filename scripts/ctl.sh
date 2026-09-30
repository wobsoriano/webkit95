#!/bin/bash
# Sends one command to a webkit95 started with WEBKIT95_CONTROL=1 and prints the JSON reply. Every
# command carries the per launch token the app writes to WEBKIT95_CONTROL_TOKEN_FILE (default
# build/control.token, mode 0600); without it the app answers {"error":"unauthorized..."}.
# Usage: scripts/ctl.sh [@window] <command...>   (port WEBKIT95_CONTROL_PORT, default 9395)
# Commands are listed in docs/control.md.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="$(cat "${WEBKIT95_CONTROL_TOKEN_FILE:-$ROOT/build/control.token}" 2>/dev/null)"
printf '%s %s\n' "$TOKEN" "$*" | nc -w "${CTL_WAIT:-5}" 127.0.0.1 "${WEBKIT95_CONTROL_PORT:-9395}" | head -1
