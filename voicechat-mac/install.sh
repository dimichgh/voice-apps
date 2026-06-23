#!/usr/bin/env bash
# Complete installer for voicechat-mac: ensures the omlx server + required models
# are present, then compiles VoiceChat.app. Idempotent — re-run safely.
#
#   ./install.sh                 # required models only (skips the optional ones)
#   WITH_OPTIONAL=1 ./install.sh # also pull OmniVoice (richer/cloned TTS voices)
#
# voicechat-mac is NOT self-contained: it talks to a local omlx server. This
# installs + verifies omlx and the models it serves, but you start the server
# yourself (see the hint printed at the end).
set -euo pipefail
cd "$(dirname "$0")"
source "$(cd .. && pwd)/scripts/installer-common.sh"

say "voicechat-mac installer"
ensure_arm64_mac
ensure_swift
ensure_omlx

# Models served by omlx (ids taken from OmlxConfig in Sources/VoiceChat/OmlxClient.swift).
#   chat: gemma-4-12B-it-8bit   stt: whisper-large-v3-turbo-asr-fp16   tts: Kokoro (default)
# OmniVoice is optional — the app falls back to the built-in Kokoro voice if it
# (and any designed voices) are absent.
ensure_model gemma-4-12b-it-8bit                 required "14G"
ensure_model whisper-large-v3-turbo-asr-fp16     required "1.6G"
ensure_model kokoro                              required "0.3G"
ensure_model omnivoice                           optional "2G"

say "building VoiceChat.app"
./build.sh

print_server_hint
say "Done. Launch with:  open VoiceChat.app   (after the omlx server is up)"
