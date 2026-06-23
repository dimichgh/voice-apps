#!/usr/bin/env bash
# Complete installer for murmur-wk (fully on-device, WhisperKit/CoreML/ANE):
# fetches the CoreML model + tokenizer if missing, then compiles + bundles
# MurmurWK.app. Idempotent — re-run safely.
#
#   ./install.sh             # resolve deps, fetch model+tokenizer (if missing), build
#   ./install.sh --assemble  # rebuild the model folder from browser-downloaded
#                            #   blocked files in ~/Downloads/whisperkit-dl/, then build
#   ./install.sh --dmg       # ...then also package a distributable MurmurWK.dmg
#
# Fully self-contained at runtime: no omlx server, no network. WhisperKit itself
# is a normal SwiftPM dependency (no native-lib build step).
set -euo pipefail
cd "$(dirname "$0")"
source "$(cd .. && pwd)/scripts/installer-common.sh"

VARIANT="openai_whisper-large-v3-v20240930_turbo"
MODEL_DIR="Models/$VARIANT"
TOKENIZER_DIR="Models/tokenizer"
DL_DIR="$HOME/Downloads/whisperkit-dl"
# Largest weight blob — its presence (>1GB) is our "model is complete" signal.
ENCODER_WEIGHT="$MODEL_DIR/AudioEncoder.mlmodelc/weights/weight.bin"

model_complete() {
    [[ -f "$ENCODER_WEIGHT" ]] && [[ "$(stat -f%z "$ENCODER_WEIGHT" 2>/dev/null || echo 0)" -gt 1000000000 ]]
}
tokenizer_complete() { compgen -G "$TOKENIZER_DIR/*.json" >/dev/null 2>&1; }

# Reconstruct the model folder from browser-downloaded flat files. The manifest
# (MANUAL_DOWNLOAD.txt) names each blocked file as  A__B__C.bin  where __ maps to
# a path separator under the model folder. Combine with the small non-LFS files
# that snapshot_download already fetched.
assemble_from_downloads() {
    [[ -d "$DL_DIR" ]] || die "expected browser downloads in $DL_DIR (see MANUAL_DOWNLOAD.txt)."
    say "reconstructing $MODEL_DIR from $DL_DIR"
    local n=0
    for f in "$DL_DIR"/*__*; do
        [[ -e "$f" ]] || continue
        local rel dest
        rel="$(basename "$f" | sed 's#__#/#g')"
        dest="$MODEL_DIR/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest"
        n=$((n + 1))
    done
    say "placed $n file(s)"
}

say "murmur-wk installer"
ensure_arm64_mac
ensure_swift

WANT_ASSEMBLE=0; WANT_DMG=0
for arg in "$@"; do
    case "$arg" in
        --assemble) WANT_ASSEMBLE=1 ;;
        --dmg)      WANT_DMG=1 ;;
        *) die "unknown option: $arg (use --assemble and/or --dmg)" ;;
    esac
done

[[ "$WANT_ASSEMBLE" == 1 ]] && assemble_from_downloads

# --- model + tokenizer ----------------------------------------------------
if model_complete && tokenizer_complete; then
    say "model + tokenizer present ($(du -sh "$MODEL_DIR" | awk '{print $1}'))"
else
    say "model and/or tokenizer missing — attempting download via huggingface_hub"
    ensure_venv   # only needs huggingface_hub; the app itself is server-free
    mkdir -p Models
    # Small (non-LFS) files always succeed; the big weight.bin blobs 403 behind
    # the corporate proxy. snapshot_download is resumable, so this is safe to retry.
    "$PY" - "$VARIANT" "$MODEL_DIR" "$TOKENIZER_DIR" <<'PY' || true
import sys
from huggingface_hub import snapshot_download
variant, model_dir, tok_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    snapshot_download("argmaxinc/whisperkit-coreml",
                      allow_patterns=[f"{variant}/*"], local_dir="Models")
except Exception as e:
    print(f"   model pull incomplete: {e}")
try:
    snapshot_download("openai/whisper-large-v3",
                      allow_patterns=["*.json", "merges.txt"], local_dir=tok_dir)
except Exception as e:
    print(f"   tokenizer pull incomplete: {e}")
PY

    if ! model_complete; then
        hr
        warn "CoreML model weights did not download completely."
        if [[ "${BROWSER:-0}" == "1" ]]; then
            say "opening the download manifest in your browser…"
            open "$(pwd)/whisperkit-download.html" >/dev/null 2>&1 || warn "couldn't open a browser — see the files below."
        fi
        cat >&2 <<EOF

  If your network blocks command-line Hugging Face downloads, pull the weights
  via browser instead — re-run with  BROWSER=1 ./install.sh  to open the manifest,
  or open it yourself:
      open "$(pwd)/whisperkit-download.html"     # clickable list, or
      cat  "$(pwd)/MANUAL_DOWNLOAD.txt"          # URLs + save-as names
  Save each file with its EXACT name into  $DL_DIR , then reassemble and build:
      ./install.sh --assemble

EOF
        hr
        die "model required to build a usable app."
    fi
    if ! tokenizer_complete; then
        warn "tokenizer missing — fetch it (small, normally not blocked):"
        warn "  huggingface-cli download openai/whisper-large-v3 --include '*.json' 'merges.txt' --local-dir $TOKENIZER_DIR"
        die "tokenizer required."
    fi
    say "model + tokenizer ready"
fi

# --- compile + bundle -----------------------------------------------------
say "building MurmurWK.app (resolves WhisperKit on first build)"
./build.sh

if [[ "$WANT_DMG" == 1 ]]; then
    say "packaging MurmurWK.dmg"
    ./package-dmg.sh
fi

echo
say "First launch is slow (~1–2 min): CoreML specializes the model to your chip, then caches it."
say "Grant Microphone, Input Monitoring, and Accessibility on first run."
say "Done. Launch with:  open MurmurWK.app    (default hotkey: fn)"
