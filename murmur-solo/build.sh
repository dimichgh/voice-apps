#!/usr/bin/env bash
# Build Murmur Solo into a runnable .app bundle.
#
# Murmur Solo is fully on-device: it links a prebuilt whisper.cpp static lib
# (Frameworks/whisper/lib/libwhisper_all.a — see build-whisper.sh) and bundles
# the GGML model into the app. Like Murmur it needs Microphone, Accessibility,
# and Input Monitoring — all of which require a bundled, signed .app.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="MurmurSolo.app"
MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_SRC="Models/${MODEL_NAME}"

if [[ ! -f "Frameworks/whisper/lib/libwhisper_all.a" ]]; then
    echo "ERROR: whisper static lib missing. Run ./build-whisper.sh first." >&2
    exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/MurmurSolo"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MurmurSolo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the model. It's large (~1.6GB) and not committed — provide it in
# Models/ (download per README). The app still builds without it, but won't
# transcribe until the model is present.
if [[ -f "$MODEL_SRC" ]]; then
    echo "==> bundling model ($(du -h "$MODEL_SRC" | awk '{print $1}'))"
    cp "$MODEL_SRC" "$APP/Contents/Resources/${MODEL_NAME}"
else
    echo "WARNING: $MODEL_SRC not found — app will report 'Model not found' until you add it." >&2
fi

# Ad-hoc sign so the permission prompts appear and TCC remembers grants.
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
echo "First run: grant Microphone, Accessibility, and Input Monitoring."
echo "Default trigger is Right ⌘ (so it won't clash with Murmur's Right ⌥)."
