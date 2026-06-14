#!/usr/bin/env bash
# Build Murmur Solo and package it as a distributable .dmg (drag-to-Applications).
# Ad-hoc signed, NOT notarized — on the target Mac, first launch needs
# right-click → Open (or: xattr -dr com.apple.quarantine the installed app).
# Apple Silicon, macOS 13+.
set -euo pipefail
cd "$(dirname "$0")"

APP="MurmurSolo.app"
DMG="MurmurSolo.dmg"
VOL="Murmur Solo"

./build.sh

if [[ ! -f "$APP/Contents/Resources/ggml-large-v3-turbo.bin" ]]; then
    echo "WARNING: model is not bundled — the .dmg will install an app that can't transcribe." >&2
    echo "         Put the model at Models/ggml-large-v3-turbo.bin and re-run (see README)." >&2
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
echo "==> creating $DMG (this compresses ~1.6GB of model — takes a minute)"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> built $(pwd)/$DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "Install: open the .dmg, drag Murmur Solo to Applications."
echo "First launch on a new Mac: right-click the app → Open (unsigned/ad-hoc)."
