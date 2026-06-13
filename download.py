#!/usr/bin/env python3
"""download.py — robust, resumable HuggingFace model downloader.

Wraps snapshot_download with:
  - hf_transfer enabled (parallel chunked downloads, ~5-10x faster)
  - Stall watchdog: kills + retries if no bytes downloaded for --stall-secs
  - Exponential backoff on transient failures
  - Idempotent across runs (HF cache ETags skip completed files)
  - Accepts catalog slugs (from mlxmgr.py) or raw HF repo ids

Usage:
  ./download.py omnivoice voxcpm2 gemma-4-12b-8bit
  ./download.py mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit  # raw repo id
  ./download.py --resume-installed     # re-verify everything already in cache
  ./download.py --stall-secs 60 omnivoice  # tighter stall threshold

Re-run any failed invocation: each completed file is skipped (HF cache ETags),
and partially-downloaded shards resume from their last byte offset.
"""
from __future__ import annotations

# Re-exec inside the local .venv if available so callers don't need to activate
# it first. We compare sys.prefix (a venv overrides it) rather than the
# executable path, because .venv/bin/python is a symlink to the base Python
# and realpath() comparisons would always match.
import os as _os, sys as _sys
_VENV_DIR = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), ".venv")
_VENV_PY = _os.path.join(_VENV_DIR, "bin", "python")
if _os.path.isfile(_VENV_PY) and _os.path.abspath(_sys.prefix) != _os.path.abspath(_VENV_DIR):
    _os.execv(_VENV_PY, [_VENV_PY, __file__, *_sys.argv[1:]])

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from mlxmgr import CATALOG, hf_snapshot_dir, human  # noqa: E402

# Child-process script that actually performs the download. We spawn this so
# we can kill it on stall and let it resume on the next attempt.
CHILD = r"""
import os, sys
from huggingface_hub import snapshot_download
repo = sys.argv[1]
workers = int(sys.argv[2]) if len(sys.argv) > 2 else 8
try:
    snapshot_download(repo_id=repo, max_workers=workers)
except Exception as e:
    print(f"CHILD ERROR: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(2)
"""


def cleanup_stale_incompletes(repo: str) -> int:
    """Remove .incomplete files that are no longer useful.

    Two cases are pure noise:
      1. Zero-byte .incomplete (killed before any data arrived)
      2. .incomplete whose corresponding final blob already exists (the
         download succeeded into a different temp suffix and renamed; this
         orphan is dead weight)

    Returns the count removed.
    """
    blobs = hf_snapshot_dir(repo) / "blobs"
    if not blobs.exists():
        return 0
    n = 0
    for p in blobs.glob("*.incomplete"):
        try:
            # Extract the blob hash (everything before the first "." after
            # the 64-char sha256). filename pattern: <sha>.<suffix>.incomplete
            stem = p.name.split(".incomplete")[0]
            blob_hash = stem.split(".")[0]
            final_blob = blobs / blob_hash
            if p.stat().st_size == 0 or final_blob.exists():
                p.unlink()
                n += 1
        except OSError:
            pass
    return n


def repo_cache_bytes(repo: str) -> int:
    """Bytes downloaded for this repo (blobs dir, including .incomplete)."""
    base = hf_snapshot_dir(repo)
    blobs = base / "blobs"
    if not blobs.exists():
        return 0
    total = 0
    for p in blobs.iterdir():
        try:
            total += p.stat().st_size
        except OSError:
            pass
    return total


def has_incomplete(repo: str) -> bool:
    blobs = hf_snapshot_dir(repo) / "blobs"
    return blobs.exists() and any(blobs.glob("*.incomplete"))


def looks_complete(repo: str) -> bool:
    """True only if every file the snapshot points at actually exists on disk.

    Verifies every symlink under snapshots/<rev>/ resolves to a non-zero blob.
    Also confirms the safetensors shards listed in model.safetensors.index.json
    (if present) are all materialised. Catches the case where we have the
    config + tokenizer but the model shards never downloaded.
    """
    import json as _json
    base = hf_snapshot_dir(repo)
    blobs = base / "blobs"
    snaps = base / "snapshots"
    if not blobs.exists() or not snaps.exists():
        return False
    # Walk the most recent snapshot
    snap_dirs = [d for d in snaps.iterdir() if d.is_dir()]
    if not snap_dirs:
        return False
    snap = max(snap_dirs, key=lambda d: d.stat().st_mtime)

    files = list(snap.iterdir())
    if not files:
        return False
    # Every symlink must resolve and target must be non-zero.
    for f in files:
        if f.is_symlink():
            target = f.resolve()
            if not target.exists() or target.stat().st_size == 0:
                return False
        elif f.is_file() and f.stat().st_size == 0:
            return False
    # If there's a sharded-safetensors index, every referenced shard must exist.
    idx = snap / "model.safetensors.index.json"
    if idx.exists():
        try:
            data = _json.loads(idx.read_text())
            for shard in set(data.get("weight_map", {}).values()):
                shard_path = snap / shard
                if not shard_path.exists():
                    return False
                resolved = shard_path.resolve() if shard_path.is_symlink() else shard_path
                if not resolved.exists() or resolved.stat().st_size == 0:
                    return False
        except (OSError, ValueError):
            return False
    # Straggling .incomplete files only count against completeness if their
    # corresponding final blob is missing — otherwise they're orphans from
    # earlier killed attempts and harmless.
    for p in blobs.iterdir():
        if not p.name.endswith(".incomplete"):
            continue
        stem = p.name.split(".incomplete")[0]
        blob_hash = stem.split(".")[0]
        if not (blobs / blob_hash).exists():
            return False
    return True


def _ensure_hf_transfer() -> Optional[str]:
    """Check hf_transfer is importable. Returns warning message if missing."""
    try:
        import hf_transfer  # noqa: F401
        return None
    except ImportError:
        return ("hf_transfer not installed — downloads will use the slow vanilla "
                "client. Fix:  pip install hf_transfer")


def download_once(repo: str, stall_secs: int,
                  use_hf_transfer: bool, workers: int) -> int:
    """Spawn one snapshot_download subprocess; kill on stall. Returns exit code.

    Exit codes: 0 success, 2 child raised, 124 watchdog killed, >0 other.
    """
    env = os.environ.copy()
    env["HF_HUB_ENABLE_HF_TRANSFER"] = "1" if use_hf_transfer else "0"
    proc = subprocess.Popen(
        [sys.executable, "-c", CHILD, repo, str(workers)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    last_bytes = repo_cache_bytes(repo)
    last_change = time.time()
    started = time.time()
    grace_period = 30  # first 30s give the HEAD/resolve roundtrips a chance

    try:
        while True:
            rc = proc.poll()
            if rc is not None:
                # Drain stderr for diagnostics
                stderr = proc.stderr.read() if proc.stderr else ""
                if rc != 0 and stderr:
                    print(f"    child stderr tail: {stderr.strip().splitlines()[-3:]}",
                          file=sys.stderr)
                return rc

            time.sleep(3)
            now_bytes = repo_cache_bytes(repo)
            elapsed = time.time() - started
            since_change = time.time() - last_change

            if now_bytes != last_bytes:
                delta_mb = (now_bytes - last_bytes) / (1024 * 1024)
                window = since_change
                rate = delta_mb / window if window > 0 else 0
                print(f"    [{repo}] {human(now_bytes):>8}  "
                      f"+{delta_mb:>6.1f}MB / {window:>5.0f}s  ({rate:.1f}MB/s)")
                last_bytes = now_bytes
                last_change = time.time()
            elif elapsed > grace_period and since_change > stall_secs:
                print(f"    [{repo}] STALL ({since_change:.0f}s no growth) — killing child")
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
                return 124
    except KeyboardInterrupt:
        print("    interrupt — stopping child")
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=5)
        raise


def download_with_retry(repo: str, max_attempts: int, stall_secs: int,
                        force_no_hf_transfer: bool = False) -> bool:
    if looks_complete(repo) and not has_incomplete(repo):
        print(f"==> {repo}: already complete ({human(repo_cache_bytes(repo))})")
        return True

    # Strategy: try hf_transfer first (fast). After 2 stalls, fall back to
    # vanilla single-connection downloads (slower but resumes via HTTP Range
    # headers — much more reliable on flaky/throttled connections).
    stall_count = 0
    for attempt in range(1, max_attempts + 1):
        if looks_complete(repo):
            print(f"==> {repo}: complete ({human(repo_cache_bytes(repo))})")
            return True

        removed = cleanup_stale_incompletes(repo)
        if removed:
            print(f"    cleaned {removed} zero-byte .incomplete files")

        use_hf_transfer = (not force_no_hf_transfer) and stall_count < 2
        workers = 8 if use_hf_transfer else 2
        mode = "hf_transfer" if use_hf_transfer else "vanilla (slow but robust)"
        print(f"==> {repo}  attempt {attempt}/{max_attempts}  mode={mode}  "
              f"(have {human(repo_cache_bytes(repo))})")

        t0 = time.time()
        rc = download_once(repo, stall_secs, use_hf_transfer, workers)
        elapsed = time.time() - t0

        if rc == 0:
            print(f"    DONE in {elapsed:.0f}s — total {human(repo_cache_bytes(repo))}")
            if looks_complete(repo):
                return True
            print(f"    warning: child exited 0 but cache still has .incomplete; retrying")
        elif rc == 124:
            stall_count += 1
            print(f"    STALLED ({stall_count} stalls so far) after {elapsed:.0f}s")
            if stall_count == 2 and not force_no_hf_transfer:
                print(f"    >>> hf_transfer not making progress — falling back to vanilla")
        else:
            print(f"    rc={rc} after {elapsed:.0f}s")

        if attempt < max_attempts:
            backoff = min(60, 5 * (2 ** min(attempt - 1, 4)))
            print(f"    sleep {backoff}s before next attempt")
            time.sleep(backoff)
    return False


def resolve(arg: str) -> str:
    if arg in CATALOG:
        e = CATALOG[arg]
        if e.kind != "hf":
            sys.exit(f"slug {arg!r} is not a HuggingFace repo (kind={e.kind})")
        return e.repo
    if "/" in arg:
        return arg
    sys.exit(f"unknown slug and not a repo id: {arg!r}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("targets", nargs="*",
                   help="catalog slugs or HF repo ids (e.g. mlx-community/Foo)")
    p.add_argument("--resume-installed", action="store_true",
                   help="re-verify every cached repo (useful after a crash)")
    p.add_argument("--stall-secs", type=int, default=120,
                   help="kill + retry if no bytes for this many seconds (default 120)")
    p.add_argument("--max-attempts", type=int, default=5,
                   help="per-repo retry budget (default 5)")
    p.add_argument("--no-hf-transfer", action="store_true",
                   help="skip hf_transfer entirely (use vanilla downloads from the start)")
    args = p.parse_args(argv)

    warning = _ensure_hf_transfer()
    if warning:
        print(f"!! {warning}\n")

    if args.resume_installed:
        targets = [e.repo for e in CATALOG.values()
                   if e.kind == "hf" and hf_snapshot_dir(e.repo).exists()]
        if not targets:
            print("nothing cached yet")
            return 0
    elif args.targets:
        targets = [resolve(t) for t in args.targets]
    else:
        p.error("specify targets or --resume-installed")

    if not os.environ.get("HF_TOKEN") and not Path.home().joinpath(
            ".cache/huggingface/token").exists():
        print("!! No HF auth detected. Unauthenticated downloads are heavily")
        print("   rate-limited by the HF CDN, which often manifests as stalls")
        print("   on large shards. Recommended:")
        print("     huggingface-cli login")
        print("   or set HF_TOKEN env var.\n")

    failed = []
    t0 = time.time()
    for repo in targets:
        ok = download_with_retry(repo, args.max_attempts, args.stall_secs,
                                 force_no_hf_transfer=args.no_hf_transfer)
        if not ok:
            failed.append(repo)

    print()
    print(f"=== summary ({time.time() - t0:.0f}s total) ===")
    for repo in targets:
        mark = "✓" if looks_complete(repo) else "✗"
        print(f"  {mark} {repo}  {human(repo_cache_bytes(repo))}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
