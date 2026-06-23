#!/usr/bin/env bash
# Build Murmur WK and package it as a distributable .dmg (drag-to-Applications).
# The CoreML model + tokenizer are bundled inside the .app, so the result is
# fully offline. Ad-hoc signed, NOT notarized — on the target Mac, first launch
# needs right-click → Open (or xattr -dr com.apple.quarantine the installed app).
# Apple Silicon, macOS 13+.
set -euo pipefail
cd "$(dirname "$0")"

APP="MurmurWK.app"
DMG="MurmurWK.dmg"
VOL="Murmur WK"
MODEL_WEIGHT="$APP/Contents/Resources/openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/weights/weight.bin"

./build.sh

if [[ ! -f "$MODEL_WEIGHT" ]] || [[ "$(stat -f%z "$MODEL_WEIGHT" 2>/dev/null || echo 0)" -lt 1000000000 ]]; then
    echo "WARNING: CoreML model is not bundled — the .dmg will install an app that can't transcribe." >&2
    echo "         Run ./install.sh (or add Models/ per README) and re-run this." >&2
fi

STAGING="$(mktemp -d)"
cp -Rp "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
echo "==> creating $DMG (compresses ~1.5GB of model — takes a minute)"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> built $(pwd)/$DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "Install: open the .dmg, drag Murmur WK to Applications."
echo "First launch on a new Mac: right-click the app → Open (unsigned/ad-hoc),"
echo "then expect a one-time ~1–2 min CoreML specialization before it transcribes."
