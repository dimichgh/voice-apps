#!/usr/bin/env bash
# Bootstrap the MLX local-AI stack for Apple Silicon (M5 / 128GB target).
# Idempotent: rerun safely.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$ROOT/.venv"
PY="${PYTHON:-python3}"
DO_WEIGHTS="${PULL_WEIGHTS:-0}"

say() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n" "$*" >&2; }

# Sanity check: must be arm64 macOS.
if [[ "$(uname)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  warn "This stack targets Apple Silicon macOS. Detected $(uname) / $(uname -m). Aborting."
  exit 1
fi

say "Python: $($PY --version)"

# 1. Create / refresh venv.
if [[ ! -d "$VENV" ]]; then
  say "Creating venv at $VENV"
  "$PY" -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade --quiet pip wheel setuptools

# 2. Core MLX runtimes + hf_transfer (parallel chunked downloads).
say "Installing MLX runtimes: mlx, mlx-lm, mlx-vlm, mlx-audio, huggingface_hub, hf_transfer"
pip install --upgrade --quiet \
  mlx \
  mlx-lm \
  mlx-vlm \
  mlx-audio \
  huggingface_hub \
  hf_transfer

# 3. MLX fine-tuning (TTS / STT / LLM via mlx-tune).
say "Installing mlx-tune (fine-tuning harness)"
pip install --upgrade --quiet "git+https://github.com/ARahim3/mlx-tune.git" || \
  warn "mlx-tune install failed (non-fatal). You can retry later with: pip install git+https://github.com/ARahim3/mlx-tune.git"

# 4. MLX-native video stacks.
EXT="$ROOT/ext"
mkdir -p "$EXT"

clone_or_pull() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    say "Updating $dest"
    git -C "$dest" pull --ff-only --quiet || warn "git pull failed for $dest"
  else
    say "Cloning $url -> $dest"
    git clone --depth 1 --quiet "$url" "$dest"
  fi
}

clone_or_pull "https://github.com/Blaizzy/mlx-video.git"    "$EXT/mlx-video"
clone_or_pull "https://github.com/dgrauet/ltx-2-mlx.git"    "$EXT/ltx-2-mlx"

# Editable installs so generate.py CLIs work.
for repo in "$EXT/mlx-video" "$EXT/ltx-2-mlx"; do
  if [[ -f "$repo/pyproject.toml" || -f "$repo/setup.py" ]]; then
    say "pip install -e $(basename "$repo")"
    pip install --quiet -e "$repo" || warn "Editable install failed for $repo (you may need to read its README for extra steps)"
  fi
done

# 5. Optional weight pulls — opt in via PULL_WEIGHTS=1.
if [[ "$DO_WEIGHTS" == "1" ]]; then
  say "Pulling default weights (this can take a long time + tens of GB)"
  python - <<'PY'
from huggingface_hub import snapshot_download
defaults = [
    # LLM — Qwen3-Coder MoE 30B-A3B 4-bit (placeholder repo name; mlxmgr.py
    # has the canonical list — keep in sync if you update either).
    ("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "LLM / coding"),
    # Voice — OmniVoice MLX bf16.
    ("mlx-community/OmniVoice-bf16", "Voice / TTS"),
]
for repo, label in defaults:
    print(f"\n--> {label}: {repo}")
    try:
        snapshot_download(repo_id=repo)
    except Exception as e:
        print(f"   skipped: {e}")
PY
else
  say "Skipping weight downloads. Set PULL_WEIGHTS=1 to pre-fetch the defaults, or use ./mlxmgr.py install <slug>."
fi

say "Done. Activate with:  source $VENV/bin/activate"
say "Then:  ./mlxmgr.py list"
