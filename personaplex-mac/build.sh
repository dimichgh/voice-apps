#!/usr/bin/env bash
# Build PersonaPlexMac and package it as a .app.
#
# The bundle is not optional: SwiftUI needs it for microphone TCC, and a bare
# binary run from the terminal inherits the terminal's mic grant instead of
# owning its own. The ad-hoc signature keeps the bundle identity stable across
# rebuilds so macOS does not re-prompt for the mic every time.
set -euo pipefail

CONFIG="${CONFIG:-release}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEECH_SWIFT="$HERE/../ext/speech-swift"
APP="$HERE/PersonaPlexMac.app"

cd "$HERE"

# mlx.metallib is produced by speech-swift's Makefile, not by SwiftPM. It needs
# the Metal toolchain: xcodebuild -downloadComponent MetalToolchain
METALLIB="$SPEECH_SWIFT/.build/$CONFIG/mlx.metallib"
if [ ! -f "$METALLIB" ]; then
    echo "==> building mlx.metallib in speech-swift"
    (cd "$SPEECH_SWIFT" && ./scripts/build_mlx_metallib.sh "$CONFIG")
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --disable-sandbox

BIN="$HERE/.build/$CONFIG/PersonaPlexMac"

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp "$METALLIB" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PersonaPlexMac</string>
    <key>CFBundleIdentifier</key><string>local.personaplex.mac</string>
    <key>CFBundleName</key><string>PersonaPlex</string>
    <key>CFBundleDisplayName</key><string>PersonaPlex</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>PersonaPlex listens and speaks at the same time, so it needs the microphone for the whole conversation.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: stable identity => the mic grant survives rebuilds.
codesign --force --sign - --deep "$APP" 2>/dev/null || \
    echo "warning: codesign failed; macOS may re-prompt for mic access"

echo "==> built $APP"
echo "    open $APP"
echo "    headless A/B:  $APP/Contents/MacOS/PersonaPlexMac --bench ../hello.wav 450"
