#!/usr/bin/env bash
# Build yue2-mac into a runnable .app bundle.
# The app starts the Python server (server/server.py under ../.venv-yue2) itself
# if nothing is listening on 127.0.0.1:8810.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="YuE2.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/YuE2"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YuE2"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null

echo "==> built $(pwd)/$APP"
echo "Launch with:  open $APP"
