#!/bin/bash
# Builds the Swift app and assembles build/webkit95.app (bundle id dev.webkit95.browser), ad hoc
# signed, with the pixel art .icns, the Ark Pixel fonts and their OFL license.
# Debug by default, which includes the dev control socket (off unless WEBKIT95_CONTROL=1).
# WEBKIT95_RELEASE=1 builds release, which has no control socket and no Web Inspector.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/webkit95.app"
BUNDLE_ID="dev.webkit95.browser"
CONFIG=debug
[ -n "${WEBKIT95_RELEASE:-}" ] && CONFIG=release

cd "$ROOT"
timeout 900 swift build -c "$CONFIG" --product webkit95
BIN="$(swift build -c "$CONFIG" --product webkit95 --show-bin-path)/webkit95"

ICONS="$ROOT/build/icons"
mkdir -p "$ICONS"
if [ ! -x "$ICONS/make-icns" ] || [ "$ROOT/Sources/Webkit95Kit/Icons.swift" -nt "$ICONS/make-icns" ] || [ "$ROOT/scripts/make-icns.swift" -nt "$ICONS/make-icns" ]; then
  # Top level code must live in a file named main.swift when compiling several files.
  cp "$ROOT/scripts/make-icns.swift" "$ICONS/main.swift"
  xcrun swiftc -O -o "$ICONS/make-icns" "$ROOT/Sources/Webkit95Kit/Win95Style.swift" "$ROOT/Sources/Webkit95Kit/Icons.swift" "$ICONS/main.swift"
fi
rm -rf "$ICONS/webkit95.iconset"
"$ICONS/make-icns" "$ICONS/webkit95.iconset" >/dev/null
iconutil -c icns -o "$ICONS/webkit95.icns" "$ICONS/webkit95.iconset"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/webkit95"
cp "$ICONS/webkit95.icns" "$APP/Contents/Resources/webkit95.icns"
cp "$ROOT"/Resources/Fonts/*.ttf "$ROOT"/Resources/Fonts/OFL-ArkPixel.txt "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>webkit95</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>webkit95</string>
  <key>CFBundleDisplayName</key><string>webkit95</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleIconFile</key><string>webkit95</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>A website you allow can use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you allow can use the microphone.</string>
  <key>NSHumanReadableCopyright</key><string>An homage, not affiliated with Microsoft. Ark Pixel font by TakWolf, SIL OFL 1.1.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "bundled $APP ($CONFIG)"
