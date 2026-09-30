#!/bin/bash
# Runs build/webkit95.app's binary with stderr captured to WEBKIT95_LOG (default build/run.log).
# Env the app reads:
#   WEBKIT95_CONTROL=1          dev control socket on 127.0.0.1:${WEBKIT95_CONTROL_PORT:-9395} (debug builds),
#                               token in ${WEBKIT95_CONTROL_TOKEN_FILE:-build/control.token}
#   WEBKIT95_BACKGROUND=1       open the first window without activating the app
#   WEBKIT95_SUPPORT_DIR        favorites, typed addresses and the hit counter (default Application Support/webkit95)
#   WEBKIT95_DOWNLOAD_DIR       downloads (debug builds only, default ~/Downloads)
#   WEBKIT95_AGENT_COMMAND      ACP agent to launch instead of `fx acp` (tests use the fake agent)
#   WEBKIT95_AGENT_MODEL        fx model id, passed as `fx acp --model <id>`
#   WEBKIT95_AGENT_ISOLATE_HOME=1  give the WEBKIT95_AGENT_COMMAND agent the private fx HOME too
#   AI_GATEWAY_API_KEY, VERCEL_OIDC_TOKEN, FX_PROVIDER   passed through to fx untouched
# Unless set, the support and download dirs default to a fresh temp dir here, so a dev run never
# reads or writes the real favorites or ~/Downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${WEBKIT95_LOG:-$ROOT/build/run.log}"
mkdir -p "$(dirname "$LOG")"
if [ -z "${WEBKIT95_SUPPORT_DIR:-}" ] || [ -z "${WEBKIT95_DOWNLOAD_DIR:-}" ]; then
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/webkit95-run.XXXXXX")"
  export WEBKIT95_SUPPORT_DIR="${WEBKIT95_SUPPORT_DIR:-$SCRATCH/support}"
  export WEBKIT95_DOWNLOAD_DIR="${WEBKIT95_DOWNLOAD_DIR:-$SCRATCH/downloads}"
  mkdir -p "$WEBKIT95_DOWNLOAD_DIR"
fi
exec "$ROOT/build/webkit95.app/Contents/MacOS/webkit95" "$@" > "$LOG" 2>&1
