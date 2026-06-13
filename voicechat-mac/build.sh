#!/usr/bin/env bash
# Build voicechat-mac into a runnable .app bundle.
# Microphone permission requires a bundled Info.plist with NSMicrophoneUsageDescription,
# so `swift run` alone won't grant access — you must launch the .app.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="VoiceChat.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/VoiceChat"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceChat"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Voice presets (designed via design_voices.py). Optional — the app falls back
# to a built-in Kokoro default if voices/ is empty or missing.
if [[ -f voices/voices.json ]]; then
    mkdir -p "$APP/Contents/Resources/voices"
    cp voices/voices.json "$APP/Contents/Resources/voices/"
    if compgen -G "voices/*.wav" > /dev/null; then
        cp voices/*.wav "$APP/Contents/Resources/voices/"
    fi
    echo "    bundled $(jq -r '.voices | length' voices/voices.json 2>/dev/null || echo '?') voice presets"
fi

# Ad-hoc sign so macOS lets the mic prompt appear.
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> built $(pwd)/$APP"
echo "Launch with:  open $APP"
echo "First run will prompt for Microphone access."
