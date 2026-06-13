#!/usr/bin/env python3
"""bench.py — measure what the research couldn't on this exact M5 / 128GB.

Closes the open questions:
  - LLM: prefill + decode tok/s for installed mlx-lm models at 4/6/8-bit
  - Voice: OmniVoice / Higgs Audio v3 synth latency (s / s-of-audio)
  - Video: LTX-2.3 wall-clock for a 5-second 720p clip

Usage:
  ./bench.py                     run all benchmarks for installed models
  ./bench.py <slug>              run only this model
  ./bench.py --out report.md     write markdown report (default: bench_report.md)
  ./bench.py --quick             smaller prompts / shorter outputs

The numbers go to stdout AND bench_report.md so you can paste them anywhere.
"""
from __future__ import annotations

# Re-exec inside the local .venv if available. Compare sys.prefix (a venv
# overrides it) rather than the executable path, because .venv/bin/python is
# a symlink to the base Python and realpath() comparisons always match.
import os as _os, sys as _sys
_VENV_DIR = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), ".venv")
_VENV_PY = _os.path.join(_VENV_DIR, "bin", "python")
if _os.path.isfile(_VENV_PY) and _os.path.abspath(_sys.prefix) != _os.path.abspath(_VENV_DIR):
    _os.execv(_VENV_PY, [_VENV_PY, __file__, *_sys.argv[1:]])

import argparse
import importlib
import json
import platform
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

# Reuse the catalog from mlxmgr.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mlxmgr import CATALOG, Entry, installed, hf_snapshot_dir, EXT, human, disk_bytes  # noqa: E402

ROOT = Path(__file__).resolve().parent
DEFAULT_REPORT = ROOT / "bench_report.md"

LLM_PROMPT = (
    "Write a Python function that implements a thread-safe LRU cache with "
    "configurable TTL per entry. Include docstrings, type hints, and three unit "
    "tests using pytest. Explain your design choices in comments."
)
LLM_PROMPT_QUICK = "Write a one-line Python function that reverses a string."
TTS_TEXT = (
    "The quick brown fox jumps over the lazy dog. The five boxing wizards jump quickly. "
    "Pack my box with five dozen liquor jugs."
)


def _hw_info() -> dict:
    try:
        chip = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip()
    except Exception:
        chip = platform.processor() or "unknown"
    try:
        mem = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip()
        mem_gb = round(int(mem) / (1024 ** 3))
    except Exception:
        mem_gb = 0
    return {
        "chip": chip,
        "memory_gb": mem_gb,
        "python": platform.python_version(),
        "macos": platform.mac_ver()[0],
    }


def _mlx_version() -> str:
    try:
        mlx = importlib.import_module("mlx")
        return getattr(mlx, "__version__", "unknown")
    except Exception as e:
        return f"error: {e}"


# --------------------------------------------------------------------------
# LLM benchmark — parse mlx_lm.generate output
# --------------------------------------------------------------------------

def bench_llm(entry: Entry, quick: bool) -> dict:
    prompt = LLM_PROMPT_QUICK if quick else LLM_PROMPT
    max_tokens = 64 if quick else 256
    cmd = [
        sys.executable, "-m", "mlx_lm.generate",
        "--model", entry.repo,
        "--prompt", prompt,
        "--max-tokens", str(max_tokens),
        "--temp", "0.0",
    ]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    elapsed = time.perf_counter() - t0
    out = proc.stdout + proc.stderr

    # mlx-lm prints something like:
    #   Prompt: 12 tokens, 234.5 tokens-per-sec
    #   Generation: 256 tokens, 67.8 tokens-per-sec
    prompt_toks, prompt_tps = _parse_tps(out, r"Prompt:\s*(\d+)\s+tokens,\s*([\d.]+)\s*tokens-per-sec")
    gen_toks, gen_tps = _parse_tps(out, r"Generation:\s*(\d+)\s+tokens,\s*([\d.]+)\s*tokens-per-sec")

    return {
        "slug": entry.slug,
        "repo": entry.repo,
        "elapsed_s": round(elapsed, 2),
        "prompt_tokens": prompt_toks,
        "prefill_tps": prompt_tps,
        "gen_tokens": gen_toks,
        "decode_tps": gen_tps,
        "ok": proc.returncode == 0 and gen_tps is not None,
        "stderr_tail": out.strip().splitlines()[-5:] if proc.returncode != 0 else None,
    }


def _parse_tps(text: str, pattern: str):
    m = re.search(pattern, text)
    if not m:
        return None, None
    return int(m.group(1)), float(m.group(2))


# --------------------------------------------------------------------------
# Voice benchmark — measure RTF (real-time factor) for TTS
# --------------------------------------------------------------------------

def bench_voice(entry: Entry, quick: bool) -> dict:
    text = TTS_TEXT[:40] if quick else TTS_TEXT
    out_wav = ROOT / f"bench_{entry.slug}.wav"
    cmd = [
        sys.executable, "-m", "mlx_audio.tts.generate",
        "--model", entry.repo,
        "--text", text,
        "--file_prefix", str(out_wav.with_suffix("")),
    ]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    elapsed = time.perf_counter() - t0

    audio_s = _wav_duration(out_wav)
    rtf = (elapsed / audio_s) if audio_s else None
    return {
        "slug": entry.slug,
        "repo": entry.repo,
        "elapsed_s": round(elapsed, 2),
        "audio_s": round(audio_s, 2) if audio_s else None,
        "rtf": round(rtf, 3) if rtf else None,
        "ok": proc.returncode == 0 and audio_s is not None,
        "stderr_tail": (proc.stdout + proc.stderr).strip().splitlines()[-5:]
        if proc.returncode != 0 else None,
    }


def _wav_duration(wav: Path) -> float:
    """Best-effort wav duration. Returns 0 if file missing or unreadable."""
    if not wav.exists():
        # mlx-audio may write a different extension; try sibling
        for sib in wav.parent.glob(wav.stem + ".*"):
            wav = sib
            break
    if not wav.exists():
        return 0.0
    try:
        import wave
        with wave.open(str(wav), "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        # fallback: use ffprobe if available
        try:
            r = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=nw=1:nk=1", str(wav)],
                capture_output=True, text=True, timeout=10,
            )
            return float(r.stdout.strip())
        except Exception:
            return 0.0


# --------------------------------------------------------------------------
# Video benchmark — LTX-2.3 wall clock for 5s 720p
# --------------------------------------------------------------------------

def bench_video(entry: Entry, quick: bool) -> dict:
    # ltx-2-mlx CLI invocation. We don't pin flags too hard because the README
    # is the source of truth; we just record wall-clock and let user inspect
    # the produced mp4.
    dest = EXT / Path(entry.repo).stem.removesuffix(".git")
    if not dest.exists():
        return {"slug": entry.slug, "ok": False, "error": "not installed"}

    out_mp4 = ROOT / f"bench_{entry.slug}.mp4"
    seconds = 2 if quick else 5
    height = 480 if quick else 720
    cmd = [
        sys.executable, "-m", "ltx2.generate",
        "--prompt", "a calm ocean wave breaking on a rocky shore at sunset",
        "--seconds", str(seconds),
        "--height", str(height),
        "--width", str(int(height * 16 / 9)),
        "--out", str(out_mp4),
        "--low-ram",
    ]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600, cwd=str(dest))
    elapsed = time.perf_counter() - t0
    return {
        "slug": entry.slug,
        "elapsed_s": round(elapsed, 1),
        "target_seconds": seconds,
        "target_height": height,
        "out": str(out_mp4),
        "ok": proc.returncode == 0 and out_mp4.exists(),
        "stderr_tail": (proc.stdout + proc.stderr).strip().splitlines()[-10:]
        if proc.returncode != 0 else None,
    }


# --------------------------------------------------------------------------
# Driver + report
# --------------------------------------------------------------------------

def run_all(slugs: Optional[list[str]], quick: bool) -> dict:
    targets = [CATALOG[s] for s in slugs] if slugs else [
        e for e in CATALOG.values() if installed(e)
    ]
    results = {"llm": [], "voice": [], "video": []}
    for e in targets:
        if not installed(e):
            print(f"-- skipping {e.slug}: not installed")
            continue
        print(f"\n>> {e.slug}  ({e.category})")
        try:
            if e.category == "llm" and e.runner == "mlx_lm":
                r = bench_llm(e, quick)
            elif e.category == "voice" and e.runner == "mlx_audio":
                r = bench_voice(e, quick)
            elif e.category == "video" and e.runner == "ltx2":
                r = bench_video(e, quick)
            else:
                print(f"   no benchmark defined for runner={e.runner}; skipping")
                continue
        except Exception as exc:
            r = {"slug": e.slug, "ok": False, "error": str(exc)}
        print("  " + json.dumps(r, indent=2).replace("\n", "\n  "))
        results[e.category].append(r)
    return results


def write_report(out: Path, env: dict, results: dict) -> None:
    lines = [
        f"# MLX Bench — {env['chip']} / {env['memory_gb']}GB",
        "",
        f"- Run: {datetime.now().isoformat(timespec='seconds')}",
        f"- macOS: {env['macos']}  •  Python: {env['python']}  •  mlx: {env['mlx']}",
        "",
        "## LLM (mlx-lm)",
        "",
        "| slug | prompt tok | prefill tok/s | gen tok | decode tok/s | wall (s) |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for r in results["llm"]:
        lines.append(
            f"| {r['slug']} | {r.get('prompt_tokens')} | {r.get('prefill_tps')} "
            f"| {r.get('gen_tokens')} | {r.get('decode_tps')} | {r.get('elapsed_s')} |"
        )
    lines += [
        "",
        "## Voice (mlx-audio)",
        "",
        "| slug | audio (s) | wall (s) | RTF (lower=faster) |",
        "|---|---:|---:|---:|",
    ]
    for r in results["voice"]:
        lines.append(
            f"| {r['slug']} | {r.get('audio_s')} | {r.get('elapsed_s')} | {r.get('rtf')} |"
        )
    lines += [
        "",
        "## Video",
        "",
        "| slug | target | wall (s) |",
        "|---|---|---:|",
    ]
    for r in results["video"]:
        target = f"{r.get('target_seconds')}s @ {r.get('target_height')}p"
        lines.append(f"| {r['slug']} | {target} | {r.get('elapsed_s')} |")
    lines.append("")
    out.write_text("\n".join(lines))
    print(f"\n==> wrote {out}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("slugs", nargs="*", help="model slugs to bench (default: all installed)")
    p.add_argument("--out", type=Path, default=DEFAULT_REPORT)
    p.add_argument("--quick", action="store_true", help="shorter prompts/outputs for a fast sanity run")
    args = p.parse_args(argv)

    env = {**_hw_info(), "mlx": _mlx_version()}
    print(json.dumps(env, indent=2))
    results = run_all(args.slugs or None, args.quick)
    write_report(args.out, env, results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
