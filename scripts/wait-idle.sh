#!/bin/bash
# Waits (bounded) until the screen is unlocked and the user has not touched
# keyboard or mouse for N seconds. Usage: wait-idle.sh [idle=60] [max=1200]
SPIKE="$(cd "$(dirname "$0")/.." && pwd)"
NEED="${1:-60}"; MAX="${2:-1200}"; t=0
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
while :; do
  if [ "$("$SPIKE/scripts/screen-locked.sh")" = 0 ] && [ "$(idle)" -ge "$NEED" ]; then echo "idle $(idle)s after ${t}s"; exit 0; fi
  [ "$t" -ge "$MAX" ] && { echo "user still active after ${MAX}s (idle $(idle)s)"; exit 1; }
  sleep 5; t=$((t + 5))
done
