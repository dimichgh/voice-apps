#!/usr/bin/env bash
# Complete installer for murmur-mac (the omlx/MLX voice-typing variant): ensures
# the omlx server + the Whisper model are present, then compiles Murmur.app.
#
#   ./install.sh                 # Whisper STT only
#   WITH_OPTIONAL=1 ./install.sh # also pull the Qwen3-Omni model for the optional cleanup pass
#
# Murmur is NOT self-contained: it POSTs audio to a local omlx server, which you
# start yourself (hint printed at the end). For a fully-offline alternative use
# the sibling murmur-solo (whisper.cpp) or murmur-wk (WhisperKit) apps.
set -euo pipefail
cd "$(dirname "$0")"
source "$(cd .. && pwd)/scripts/installer-common.sh"

say "murmur-mac installer"
ensure_arm64_mac
ensure_swift
ensure_omlx

# Models served by omlx (ids/defaults from Sources/Murmur/Settings.swift).
#   stt: whisper-large-v3-turbo-asr-fp16   cleanup (optional, off by default): Qwen3-Omni-30B-8bit
ensure_model whisper-large-v3-turbo-asr-fp16     required "1.6G"
ensure_model qwen3-omni-30b-a3b-8bit             optional "38G"

say "building Murmur.app"
./build.sh

print_server_hint
echo
say "First run: grant Microphone, Accessibility, and Input Monitoring in"
say "System Settings › Privacy & Security. Murmur lives in the menu bar."
say "Done. Launch with:  open Murmur.app   (after the omlx server is up)"
