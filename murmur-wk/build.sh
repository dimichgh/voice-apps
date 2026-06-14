#!/usr/bin/env bash
# Build Murmur WK (WhisperKit / CoreML) into a runnable .app bundle.
# Bundles the CoreML model folder + tokenizer so it runs fully offline. Like the
# other two, needs Microphone, Accessibility, and Input Monitoring.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="MurmurWK.app"
MODEL_DIR="openai_whisper-large-v3-v20240930_turbo"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/MurmurWK"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MurmurWK"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the CoreML model + tokenizer (downloaded per README; not committed).
# Copy with -p to PRESERVE timestamps: CoreML caches its (~90s) Apple Neural
# Engine specialization keyed partly on the model files' mtime, so re-copying
# with fresh "now" timestamps silently forces a full re-specialization on the
# next launch (transcription appears to hang for ~90s). Copying with the source's
# stable mtime keeps that cache valid across rebuilds.
if [[ -d "Models/$MODEL_DIR" ]]; then
    echo "==> bundling model + tokenizer ($(du -sh Models/$MODEL_DIR | awk '{print $1}'))"
    cp -Rp "Models/$MODEL_DIR" "$APP/Contents/Resources/"
    [[ -d "Models/tokenizer" ]] && cp -Rp "Models/tokenizer" "$APP/Contents/Resources/"
else
    echo "WARNING: Models/$MODEL_DIR not found — app will report 'Model not found' until you add it." >&2
fi

# Sign with a stable self-signed identity if present (its designated
# requirement references the cert, so Input Monitoring / Accessibility grants
# survive rebuilds). Falls back to ad-hoc, where grants reset each rebuild.
SIGN_ID="${MURMUR_SIGN_ID:-Murmur Dev Signing}"
if codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "    signed with '$SIGN_ID' — TCC grants persist across rebuilds"
else
    codesign --force --deep --sign - "$APP" >/dev/null
    echo "    ad-hoc signed — TCC grants reset on each rebuild"
fi

echo "==> built $(pwd)/$APP"
echo "Launch with:  open $APP"
echo "Default trigger is fn (Murmur uses Right ⌥, Solo uses Right ⌘) — all three coexist."
