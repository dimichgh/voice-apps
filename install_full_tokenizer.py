#!/usr/bin/env python3
"""install_full_tokenizer.py — swap the acoustic-only tokenizer that
mlx-community/OmniVoice-bf16 ships for the full 806MB k2-fsa version
(includes the HuBERT semantic encoder needed for voice cloning).

Strategy:
  1. Sanity-check the source: k2-fsa file, MUST have semantic_model.* keys.
  2. Verify mlx-audio's sanitize() will accept it — call it on the keys and
     confirm 0 missing params for the SemanticEncoder + Wav2Vec2Model expected
     by HiggsAudioTokenizer.
  3. Back up the existing 146MB blob (the acoustic-only one already in cache)
     so we can roll back.
  4. Overwrite the blob in place. The HF cache's snapshot symlink stays valid
     — both the symlink target and the staging file point at the same blob
     hash on disk, just with different contents.

Idempotent: rerun is a no-op if the cache blob already matches the k2-fsa size.
"""
from __future__ import annotations

# Re-exec inside .venv if not already.
import os as _os, sys as _sys
_VENV_DIR = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), ".venv")
_VENV_PY = _os.path.join(_VENV_DIR, "bin", "python")
if _os.path.isfile(_VENV_PY) and _os.path.abspath(_sys.prefix) != _os.path.abspath(_VENV_DIR):
    _os.execv(_VENV_PY, [_VENV_PY, __file__, *_sys.argv[1:]])

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "ext" / "k2-fsa-audio_tokenizer" / "audio_tokenizer" / "model.safetensors"
HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"
OMNI_REPO_DIR = HF_CACHE / "models--mlx-community--OmniVoice-bf16"

EXPECTED_FULL_SIZE = 805_665_628  # bytes, from HF API listing


def find_audio_tokenizer_blob() -> Path:
    """Locate the audio_tokenizer/model.safetensors symlink target."""
    snapshots = OMNI_REPO_DIR / "snapshots"
    snap_dirs = list(snapshots.iterdir()) if snapshots.exists() else []
    if not snap_dirs:
        sys.exit(f"No snapshot found under {snapshots}; install omnivoice first.")
    snap = max(snap_dirs, key=lambda d: d.stat().st_mtime)
    symlink = snap / "audio_tokenizer" / "model.safetensors"
    if not symlink.exists():
        sys.exit(f"Missing {symlink}")
    return symlink.resolve()


def check_source() -> None:
    if not SRC.exists():
        sys.exit(f"Source not found: {SRC}\nRun the download step first.")
    size = SRC.stat().st_size
    if size != EXPECTED_FULL_SIZE:
        print(f"warning: source size {size} != expected {EXPECTED_FULL_SIZE} "
              "(download incomplete or upstream changed)")
    # Verify the file has semantic_model.* keys
    from safetensors import safe_open
    with safe_open(SRC, framework="numpy") as f:
        keys = list(f.keys())
    sem_keys = [k for k in keys if k.startswith(("semantic_model.", "encoder_semantic."))]
    print(f"source has {len(keys)} total keys, {len(sem_keys)} semantic_*/encoder_semantic_*")
    if len(sem_keys) < 100:
        sys.exit("source does not contain the HuBERT semantic encoder; aborting")


def main() -> int:
    check_source()
    blob = find_audio_tokenizer_blob()
    blob_size = blob.stat().st_size
    print(f"current cache blob: {blob}  ({blob_size:,} bytes)")

    if blob_size == EXPECTED_FULL_SIZE:
        print("blob already matches the full tokenizer — nothing to do.")
        return 0

    backup = blob.with_suffix(".acoustic-only.bak")
    if not backup.exists():
        print(f"backing up acoustic-only blob -> {backup.name}")
        shutil.copy2(blob, backup)

    print(f"copying full tokenizer over the cache blob ({SRC.stat().st_size:,} bytes)")
    # shutil.copy preserves the blob inode/path; the symlink in snapshots/
    # continues to point at it.
    shutil.copy2(SRC, blob)
    new_size = blob.stat().st_size
    print(f"done. blob now {new_size:,} bytes")

    # Quick verification: load with mlx-audio's sanitize to confirm key coverage
    print()
    print("=== Validating with mlx-audio sanitize ===")
    import mlx.core as mx
    from mlx_audio.codec.models.higgs_audio.higgs_audio import (
        HiggsAudioTokenizer, HiggsAudioConfig,
    )
    config_path = blob.parent / "3f9e5ee43d2134dfdc1e38055fbcb24a18af1635"
    # Resolve through the snapshot symlink instead — easier.
    snap = max((OMNI_REPO_DIR / "snapshots").iterdir(), key=lambda d: d.stat().st_mtime)
    cfg = json.loads((snap / "audio_tokenizer" / "config.json").read_text())
    inst = HiggsAudioTokenizer(HiggsAudioConfig.from_dict(cfg))
    inst._init_encode_modules()
    # The cache blob has no extension; pass format explicitly. The real
    # loader reads through the `model.safetensors` symlink and works without
    # this hint.
    raw = mx.load(str(blob), format="safetensors")
    sanitized = inst.sanitize(raw)
    expected = set(dict(inst.named_parameters()).keys())
    provided = set(sanitized.keys())
    missing = expected - provided
    extra = provided - expected
    print(f"expected={len(expected)} provided={len(provided)} "
          f"missing={len(missing)} extra={len(extra)}")
    if missing:
        print("first 10 missing:")
        for k in sorted(missing)[:10]:
            print(f"  {k}")
    if extra:
        print("first 10 extra:")
        for k in sorted(extra)[:10]:
            print(f"  {k}")
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
