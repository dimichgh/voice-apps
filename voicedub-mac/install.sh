#!/usr/bin/env bash
# Complete installer for voicedub-mac: ensures the omlx server, ffmpeg, and the
# required models are present, then compiles VoiceDub.app. Idempotent.
#
#   ./install.sh                 # core install (Demucs separation left disabled)
#   WITH_DEMUCS=1 ./install.sh   # also set up the Demucs venv for "keep background music"
#
# voicedub-mac is NOT self-contained: model ops run through a local omlx server,
# which you start yourself (hint printed at the end). ffmpeg/ffprobe are required
# for audio extraction, time-stretching, and assembly.
set -euo pipefail
cd "$(dirname "$0")"
source "$(cd .. && pwd)/scripts/installer-common.sh"

say "voicedub-mac installer"
ensure_arm64_mac
ensure_swift
ensure_cmd ffmpeg  "brew install ffmpeg"
ensure_cmd ffprobe "brew install ffmpeg"
ensure_omlx

# Models served by omlx (ids from OmlxConfig in Sources/VoiceDub/OmlxClient.swift).
#   stt: whisper-large-v3-turbo-asr-fp16   translate: Qwen3-Omni-30B-8bit   tts: OmniVoice
# All three are required for the dubbing pipeline (OmniVoice is the TTS engine here,
# not an optional upgrade as it is in voicechat).
ensure_model whisper-large-v3-turbo-asr-fp16     required "1.6G"
ensure_model qwen3-omni-30b-a3b-8bit             required "38G"
ensure_model omnivoice                           required "2G"

# Optional: Demucs voice/background separation venv (fixed path the app probes).
if [[ "${WITH_DEMUCS:-0}" == "1" ]]; then
    DEMUCS_VENV="$HOME/Library/Application Support/VoiceDub/demucs-venv"
    if [[ -x "$DEMUCS_VENV/bin/python" ]]; then
        say "Demucs venv already present"
    else
        say "setting up Demucs venv at $DEMUCS_VENV"
        ensure_cmd python3 "brew install python"
        python3 -m venv "$DEMUCS_VENV"
        # torchcodec is REQUIRED for Demucs to *write* stems on recent torchaudio.
        "$DEMUCS_VENV/bin/python" -m pip install --quiet --upgrade pip
        "$DEMUCS_VENV/bin/python" -m pip install demucs torchcodec \
            || warn "Demucs install failed — the 'keep background music' checkbox will stay disabled."
    fi
else
    say "Demucs separation not requested (re-run with WITH_DEMUCS=1 to enable it)."
fi

say "building VoiceDub.app"
./build.sh

print_server_hint
say "Done. Launch with:  open VoiceDub.app   (after the omlx server is up)"
