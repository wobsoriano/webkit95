#!/bin/sh
# Regenerates Sources/Webkit95Kit/Icons.swift from gen.py and renders contact sheets into build/icons.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$D/../.."
OUT="$ROOT/build/icons"
mkdir -p "$OUT"
python3 "$D/gen.py"
xcrun swiftc -O -o "$OUT/preview" "$ROOT/Sources/Webkit95Kit/Win95Style.swift" "$ROOT/Sources/Webkit95Kit/Icons.swift" "$D/main.swift" 2>&1 | grep -v warning || true
"$OUT/preview" "$OUT/sheet1x.png" 1 12
"$OUT/preview" "$OUT/sheet4x.png" 4 12
