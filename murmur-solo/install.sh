#!/usr/bin/env bash
# Complete installer for murmur-solo (fully on-device, whisper.cpp/Metal):
# builds the whisper.cpp static lib, fetches the GGML model if missing, then
# compiles + bundles MurmurSolo.app. Idempotent — re-run safely.
#
#   ./install.sh            # build lib (if needed), get model (if missing), build app
#   ./install.sh --dmg      # ...then also package a distributable MurmurSolo.dmg
#
# Fully self-contained at runtime: no Python, no omlx server, no network.
set -euo pipefail
cd "$(dirname "$0")"
source "$(cd .. && pwd)/scripts/installer-common.sh"

MODEL_NAME="ggml-large-v3-turbo.bin"
MODEL_PATH="Models/${MODEL_NAME}"
# whisper.cpp's official GGML weights (large download — blocked by some proxies).
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}?download=true"

say "murmur-solo installer"
ensure_arm64_mac
ensure_swift
ensure_cmd cmake "brew install cmake"

# 1) whisper.cpp static lib (clones whisper.cpp into ../ext on first run).
if [[ -f "Frameworks/whisper/lib/libwhisper_all.a" ]]; then
    say "whisper.cpp static lib already built"
else
    say "building whisper.cpp static lib (./build-whisper.sh)"
    ./build-whisper.sh
fi

# 2) the GGML model (~1.6 GB, not committed).
if [[ -f "$MODEL_PATH" ]] && [[ "$(stat -f%z "$MODEL_PATH")" -gt 100000000 ]]; then
    say "model present: $MODEL_PATH ($(du -h "$MODEL_PATH" | awk '{print $1}'))"
else
    say "model MISSING — downloading $MODEL_NAME (~1.6 GB) …"
    mkdir -p Models
    tmp="$(mktemp "Models/.${MODEL_NAME}.XXXXXX")"
    rc=0
    curl -fL --progress-bar -o "$tmp" "$MODEL_URL" || rc=$?
    # A proxy block returns a tiny HTML page with a 200/403 — sanity-check the size.
    if [[ $rc -eq 0 ]] && [[ "$(stat -f%z "$tmp")" -gt 100000000 ]]; then
        mv "$tmp" "$MODEL_PATH"
        say "model downloaded: $MODEL_PATH ($(du -h "$MODEL_PATH" | awk '{print $1}'))"
    else
        rm -f "$tmp"
        hr
        warn "Download did not complete for $MODEL_NAME."
        if [[ "${BROWSER:-0}" == "1" ]]; then
            say "opening the download in your browser…"
            open "$MODEL_URL" >/dev/null 2>&1 || warn "couldn't open a browser — visit the URL below manually."
        fi
        cat >&2 <<EOF

  Retry options:
    • Re-run this installer:  ./install.sh
    • If your network blocks command-line Hugging Face downloads, pull it via
      browser instead:  BROWSER=1 ./install.sh   (opens the URL below)
        $MODEL_URL
      then move it into place and re-run:
        mv ~/Downloads/$MODEL_NAME "$(pwd)/Models/" && ./install.sh

  (Smaller quantized variants ggml-large-v3-turbo-q8_0.bin / -q5_0.bin also work
   — rename to $MODEL_NAME.)
EOF
        hr
        die "model required to build a usable app."
    fi
fi

# 3) compile + bundle.
say "building MurmurSolo.app"
./build.sh

if [[ "${1:-}" == "--dmg" ]]; then
    say "packaging MurmurSolo.dmg"
    ./package-dmg.sh
fi

echo
say "First run: grant Microphone, Input Monitoring, and Accessibility."
say "Done. Launch with:  open MurmurSolo.app    (default hotkey: Right ⌘)"
