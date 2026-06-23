#!/usr/bin/env bash
# Shared helpers for the per-app install.sh scripts.
#
# Source it from an app installer:
#     source "$(cd "$(dirname "$0")/.." && pwd)/scripts/installer-common.sh"
#
# Provides:
#   say / warn / die / hr            — logging
#   ensure_arm64_mac                 — abort unless Apple Silicon macOS
#   ensure_cmd <cmd> [hint]          — abort if a tool is missing (with install hint)
#   PROJECT_ROOT / VENV / PY         — paths to the repo root, .venv, venv python
#   ensure_venv                      — create .venv + core deps if absent
#   ensure_omlx                      — pip install -e ext/omlx[mcp] if `omlx` missing
#   hf_cached <repo>                 — 0 if the HF snapshot dir exists, else 1
#   ensure_model <slug> [required|optional]
#                                    — install a mlxmgr catalog model if missing
#                                      (assumes a normal network). On failure it
#                                      prints retry options incl. a browser pull
#                                      (BROWSER=1 opens the page). optional => never fatal.
#   omlx_running [url]               — 0 if the server answers /v1/models
#   print_server_hint                — how to start omlx
#
# Models live in the HuggingFace cache; downloads go through mlxmgr.py so the
# catalog stays the single source of truth (see model-download-method memory).
set -euo pipefail

# Resolve the repo root from this file's location (scripts/ lives at the root).
_self="${BASH_SOURCE[0]:-$0}"
PROJECT_ROOT="$(cd "$(dirname "$_self")/.." && pwd)"
VENV="$PROJECT_ROOT/.venv"
PY="$VENV/bin/python"
HF_HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# ----- logging -------------------------------------------------------------
say()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!\033[0m %s\n"  "$*" >&2; }
die()  { printf "\033[1;31mxx\033[0m %s\n"  "$*" >&2; exit 1; }
hr()   { printf -- "------------------------------------------------------------\n"; }

# ----- environment preconditions ------------------------------------------
ensure_arm64_mac() {
    [[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
        || die "This app targets Apple Silicon macOS (detected $(uname)/$(uname -m))."
}

ensure_cmd() {
    local cmd="$1" hint="${2:-}"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    warn "required tool not found: $cmd"
    [[ -n "$hint" ]] && warn "  install it with: $hint"
    die "install $cmd and re-run."
}

# Swift toolchain (all apps need it to compile).
ensure_swift() {
    ensure_cmd swift "xcode-select --install"
    say "swift: $(swift --version 2>/dev/null | head -1)"
}

# ----- python venv + omlx server (the 'omlx family' apps) ------------------
# Create the project .venv with the minimal deps omlx needs. We deliberately do
# NOT run the repo-root install.sh: that also pulls mlx-video / ltx-2 / mlx-tune
# (network-fragile, irrelevant to these apps). omlx brings its own mlx deps.
ensure_venv() {
    if [[ ! -x "$PY" ]]; then
        say "creating venv at $VENV"
        ensure_cmd python3 "brew install python"
        python3 -m venv "$VENV"
        "$PY" -m pip install --upgrade --quiet pip wheel setuptools
        "$PY" -m pip install --quiet huggingface_hub hf_transfer
    fi
}

ensure_omlx() {
    ensure_venv
    if "$PY" -c "import omlx" >/dev/null 2>&1 || [[ -x "$VENV/bin/omlx" ]]; then
        say "omlx already installed in venv"
        return 0
    fi
    local omlx_src="$PROJECT_ROOT/ext/omlx"
    [[ -d "$omlx_src" ]] || die "omlx source missing at $omlx_src (expected the vendored ext/omlx checkout)."
    say "installing omlx server (pip install -e ext/omlx[mcp])"
    "$PY" -m pip install --quiet -e "${omlx_src}[mcp]" \
        || die "omlx install failed — see ext/omlx/README.md."
}

# ----- model presence / download ------------------------------------------
# hf_cached <hf-repo-id>  ->  0 if the snapshot dir exists in the HF cache.
hf_cached() {
    local repo="$1"
    [[ -d "$HF_HUB/models--${repo//\//--}" ]]
}

# ensure_model <slug> [required|optional] [size-hint]
# Installs the model via mlxmgr if its HF snapshot is absent. Detects the
# Netskope/HF block and prints exact manual recovery steps. snapshot_download is
# resumable, so re-running after fetching off-network is safe.
ensure_model() {
    local slug="$1" mode="${2:-required}" size="${3:-}"
    # Ask mlxmgr for the repo id behind this slug (single source of truth).
    local repo
    repo="$(cd "$PROJECT_ROOT" && "$PY" -c "import mlxmgr,sys; e=mlxmgr.CATALOG.get('$slug'); print(e.repo if e else '')" 2>/dev/null \
            || (cd "$PROJECT_ROOT" && python3 -c "import mlxmgr,sys; e=mlxmgr.CATALOG.get('$slug'); print(e.repo if e else '')" 2>/dev/null))"
    if [[ -z "$repo" ]]; then
        warn "model slug '$slug' not in mlxmgr catalog — skipping (add an Entry to mlxmgr.py)."
        [[ "$mode" == required ]] && return 1 || return 0
    fi
    if hf_cached "$repo"; then
        say "model present: $slug  ($repo)"
        return 0
    fi

    say "model MISSING: $slug  ($repo)${size:+  ~$size}  [$mode]"
    if [[ "$mode" == optional && "${WITH_OPTIONAL:-0}" != "1" ]]; then
        warn "  optional — skipping. Re-run with WITH_OPTIONAL=1 to fetch it."
        return 0
    fi

    say "downloading via mlxmgr (resumable)…"
    local out rc=0
    out="$(cd "$PROJECT_ROOT" && "$PY" mlxmgr.py install "$slug" 2>&1)" || rc=$?
    printf '%s\n' "$out"

    if [[ $rc -eq 0 ]] && hf_cached "$repo"; then
        say "model installed: $slug"
        return 0
    fi

    # Download failed. The default path assumes a normal network; offer the
    # browser route as an explicit fallback (BROWSER=1 opens the page).
    hr
    warn "Download did not complete for $slug ($repo)."
    local url="https://huggingface.co/$repo"
    if [[ "${BROWSER:-0}" == "1" ]]; then
        say "opening the model page in your browser…"
        open "$url" >/dev/null 2>&1 || warn "couldn't open a browser — visit $url manually."
    fi
    cat >&2 <<EOF

  Retry options for '$slug':
    • Re-run this installer — the download is resumable and picks up where it
      left off:   cd "$PROJECT_ROOT" && $PY mlxmgr.py install $slug
    • If your network blocks command-line Hugging Face downloads, pull it via
      browser instead:   BROWSER=1 ./install.sh   (opens $url)
      Download the repo's files there, then place them in the HF cache under
      $HF_HUB/models--${repo//\//--}/  (or re-run on a network that allows the CLI).

EOF
    hr
    [[ "$mode" == required ]] && return 1 || return 0
}

# ----- omlx server status --------------------------------------------------
omlx_running() {
    local url="${1:-http://127.0.0.1:8000}"
    curl -s -m 2 "$url/v1/models" >/dev/null 2>&1
}

print_server_hint() {
    local url="${1:-http://127.0.0.1:8000}"
    hr
    if omlx_running "$url"; then
        say "omlx server is already running at $url ✓"
    else
        say "Start the omlx server before using the app:"
        echo "    $VENV/bin/omlx serve --port 8000"
        echo "  (or:  $VENV/bin/omlx start   for the managed background daemon)"
    fi
    hr
}
