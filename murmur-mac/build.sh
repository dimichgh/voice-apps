#!/usr/bin/env bash
# Build Murmur into a runnable .app bundle.
#
# Murmur needs three macOS permissions, and ALL of them require a properly
# bundled, signed .app — `swift run` alone won't do:
#   - Microphone        (NSMicrophoneUsageDescription, below)
#   - Accessibility     (to post the ⌘V paste keystroke into other apps)
#   - Input Monitoring  (to observe the global hold-to-talk modifier key)
# Launch the built .app, then grant these in System Settings › Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="Murmur.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Murmur"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS lets the permission prompts appear and remembers the
# grants across launches (a stable code signature is what TCC keys off of).
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> built $(pwd)/$APP"
echo "Launch with:  open $APP"
echo
echo "First run: grant Microphone, Accessibility, and Input Monitoring in"
echo "System Settings › Privacy & Security. Murmur appears in the menu bar (⌥)."
