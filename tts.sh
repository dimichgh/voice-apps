#!/usr/bin/env bash
# Usage:
#   ./tts.sh "Text to speak"                         -> uses ref.wav, writes ./out.wav
#   ./tts.sh "Text to speak" my_voice.wav            -> custom reference
#   ./tts.sh "Text to speak" my_voice.wav hi.wav     -> writes to hi.wav
#
# Reference audio: 3-10s clean clip of your voice. Whisper auto-transcribes it.
# Env overrides: OMNIVOICE_MODEL, OMNIVOICE_VENV.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="${OMNIVOICE_VENV:-$ROOT/.venv}"
MODEL="${OMNIVOICE_MODEL:-mlx-community/OmniVoice-bf16}"

# Quality knobs (env-overridable)
DURATION="${OMNIVOICE_DURATION:-12}"   # seconds; default 5 clips long sentences
STEPS="${OMNIVOICE_STEPS:-48}"         # 4-64; higher = better, slower
CFG="${OMNIVOICE_CFG:-3.0}"            # CFG scale; 2.0 default, higher = follows text more
REF_TEXT="${OMNIVOICE_REF_TEXT:-}"     # exact transcript of ref_audio; skips Whisper

TEXT="${1:?Provide text as the first argument}"
REF_AUDIO="${2:-ref.wav}"
OUTPUT="${3:-out.wav}"

# Expand ~
REF_AUDIO="${REF_AUDIO/#\~/$HOME}"
OUTPUT="${OUTPUT/#\~/$HOME}"

if [[ ! -f "$REF_AUDIO" ]]; then
  echo "Reference audio not found: $REF_AUDIO" >&2
  exit 1
fi

if [[ ! -x "$VENV/bin/mlx_audio.tts.generate" ]]; then
  echo "mlx_audio.tts.generate not found in $VENV" >&2
  echo "Run ./install.sh first." >&2
  exit 1
fi

# mlx_audio writes <output_path>/<file_prefix>.<audio_format>; split OUTPUT accordingly.
OUT_DIR="$(dirname "$OUTPUT")"
OUT_NAME="$(basename "$OUTPUT")"
OUT_PREFIX="${OUT_NAME%.*}"
OUT_EXT="${OUT_NAME##*.}"
[[ "$OUT_EXT" == "$OUT_NAME" ]] && OUT_EXT="wav"
mkdir -p "$OUT_DIR"

# If reference isn't already wav, transcode via ffmpeg (mlx_audio's loader is picky).
REF_EXT="$(printf '%s' "${REF_AUDIO##*.}" | tr '[:upper:]' '[:lower:]')"
case "$REF_EXT" in
  wav) REF_INPUT="$REF_AUDIO" ;;
  *)
    if ! command -v ffmpeg >/dev/null; then
      echo "Reference is not .wav and ffmpeg is missing. brew install ffmpeg" >&2
      exit 1
    fi
    REF_INPUT="$(mktemp -t omnivoice_ref).wav"
    ffmpeg -y -loglevel error -i "$REF_AUDIO" -ac 1 -ar 24000 "$REF_INPUT"
    ;;
esac

CMD=(
  "$VENV/bin/mlx_audio.tts.generate"
  --model "$MODEL"
  --text "$TEXT"
  --ref_audio "$REF_INPUT"
  --gen_duration "$DURATION"
  --steps "$STEPS"
  --cfg_scale "$CFG"
  --output_path "$OUT_DIR"
  --file_prefix "$OUT_PREFIX"
  --audio_format "$OUT_EXT"
)
[[ -n "$REF_TEXT" ]] && CMD+=(--ref_text "$REF_TEXT")

"${CMD[@]}"

# mlx_audio appends _NNN to file_prefix; rename the first chunk to the requested name.
GENERATED="${OUT_DIR%/}/${OUT_PREFIX}_000.${OUT_EXT}"
FINAL="${OUT_DIR%/}/${OUT_PREFIX}.${OUT_EXT}"
if [[ -f "$GENERATED" ]]; then
  mv -f "$GENERATED" "$FINAL"
  echo "Wrote $FINAL"
else
  echo "Wrote (check $OUT_DIR for ${OUT_PREFIX}_*.${OUT_EXT})"
fi
