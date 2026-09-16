"""YuE2 local server for the yue2-mac app.

Runs YuE2-3B and SheetSage2 natively in MLX (vanch007/mlx-Yue, 8-bit AR +
BF16 NAR) behind a tiny job API so the SwiftUI app can submit a generation,
poll progress, and cancel. One job runs at a time (the pipeline is stateful).
Lyrics writing and lyric ASR are NOT here — the app routes those to the omlx
server, like the sibling voice apps.

    mlx-yue/.venv/bin/python yue2-mac/server/server.py --port 8810
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import threading
import time
import traceback
import uuid
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Literal, Optional

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("MLX_ENABLE_TF32", "0")

import mlx.core as mx  # noqa: E402,F401  (lyra's GPU guard requires MLX imported first)
import uvicorn  # noqa: E402
from fastapi import FastAPI, HTTPException  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

LLM_ROOT = Path(__file__).resolve().parents[2]
# Produced offline from the cached m-a-p/YuE2-3B snapshot by lyra.conversion.prepare().
CONVERTED_DIR = Path(os.environ.get("YUE2_MLX_MODEL", LLM_ROOT / "mlx-yue" / "models" / "converted"))
PRECISION = os.environ.get("YUE2_MLX_PRECISION", "8bit")
VAE_ID = "m-a-p/YuE2-Vae"
OUTPUT_ROOT = Path.home() / "Library" / "Application Support" / "YuE2" / "outputs"
DEVICE = "mlx-gpu"

app = FastAPI(title="YuE2 server")
_models_lock = threading.Lock()   # guards lazy model construction
_run_lock = threading.Lock()      # one GPU job at a time
_pipe = None
_transcriber = None
_jobs: dict[str, "Job"] = {}


# --------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------

def get_pipe():
    global _pipe
    with _models_lock:
        if _pipe is None:
            _install_lora_hook()
            from huggingface_hub import snapshot_download
            from lyra import YuE2Pipeline
            # Pass the cached VAE snapshot path: lyra pins a newer VAE revision whose
            # weights are byte-identical, and resolving that revision offline fails.
            vae = snapshot_download(VAE_ID, local_files_only=True)
            _pipe = YuE2Pipeline.from_pretrained(str(CONVERTED_DIR), vae=vae, precision=PRECISION,
                                                 progress=False, local_files_only=True)
        return _pipe


def get_transcriber():
    global _transcriber
    with _models_lock:
        if _transcriber is None:
            from lyra.transcription.model import SheetSage2
            _transcriber = SheetSage2.from_pretrained(offline=True)
        return _transcriber


# --------------------------------------------------------------------------
# Instrumental mode: AR LoRA (Mothersuperior/YuE2-instrumental-cot-full-loras)
# --------------------------------------------------------------------------
# The LoRA is folded into the weights at AR load time (W += B @ A, scale 1.0), like
# the authors' reference script, which merges into the whole model — so both the
# 8-bit sampling AR and the BF16 acoustic-conditioning AR carry it. The pipeline
# reloads those models from disk per stage anyway, so switching modes just drops
# the cached ones.

INSTRUMENTAL_LORA_REPO = "Mothersuperior/YuE2-instrumental-cot-full-loras"
INSTRUMENTAL_LORA_FILE = "ar_lora_inst_v3abc.bf16.safetensors"
_lora_active = False
_lora_weights = None
_original_load_ar = None


def instrumental_lora_path() -> Optional[Path]:
    try:
        from huggingface_hub import snapshot_download
        path = Path(snapshot_download(INSTRUMENTAL_LORA_REPO, local_files_only=True)) / INSTRUMENTAL_LORA_FILE
    except Exception:  # noqa: BLE001 — not installed
        return None
    return path if path.is_file() else None


def _merge_lora(model):
    global _lora_weights
    from mlx.utils import tree_flatten
    if _lora_weights is None:
        _lora_weights = mx.load(str(instrumental_lora_path()))
    params = dict(tree_flatten(model.parameters()))
    updates = []
    for key, lora_a in _lora_weights.items():
        if not key.endswith(".lora_A"):
            continue
        base = key[: -len(".lora_A")]              # layers.{i}.self_attn.q_proj
        name = f"model.{base}.weight"
        weight = params.get(name)
        if weight is None:
            raise KeyError(f"LoRA target {name} is not in the AR model")
        delta = _lora_weights[base + ".lora_B"].astype(mx.float32) @ lora_a.astype(mx.float32)
        updates.append((name, weight + delta.astype(weight.dtype)))
    if len(updates) != 28 * 7:
        raise ValueError(f"Expected 196 LoRA targets, merged {len(updates)}")
    model.load_weights(updates, strict=False)


def _load_ar_with_lora(directory, *, precision="bf16", verify=True):
    if not _lora_active:
        return _original_load_ar(directory, precision=precision, verify=verify)
    import mlx.nn as nn
    model = _original_load_ar(directory, precision="bf16", verify=verify)
    _merge_lora(model)
    if precision != "bf16":
        # Same scheme lyra.conversion uses for ar-8bit / ar-4bit.
        nn.quantize(model, group_size=64, bits=8 if precision == "8bit" else 4, mode="affine",
                    class_predicate=lambda _path, module: isinstance(module, nn.Linear))
    mx.eval(model.parameters())
    object.__setattr__(model, "_precision", precision)
    return model


def _install_lora_hook():
    # lyra.pipeline imports load_ar from lyra.ar at call time, so patching the module attribute works.
    global _original_load_ar
    import lyra.ar
    if _original_load_ar is None:
        _original_load_ar = lyra.ar.load_ar
        lyra.ar.load_ar = _load_ar_with_lora


def set_instrumental(pipe, wanted: bool) -> bool:
    """Switch the LoRA on/off for the next model load; returns whether it is applied."""
    global _lora_active
    active = wanted and instrumental_lora_path() is not None
    if active != _lora_active:
        _lora_active = active
        pipe._ar = pipe._bf16_ar = pipe._nar = None
        mx.synchronize()
        mx.clear_cache()
    return active


# --------------------------------------------------------------------------
# Jobs
# --------------------------------------------------------------------------

class Job:
    def __init__(self, kind: str):
        self.id = uuid.uuid4().hex[:12]
        self.kind = kind
        self.state = "queued"         # queued | running | done | error | cancelled
        self.phase = "Waiting for the GPU"
        self.tokens = 0
        self.step = 0
        self.total_steps = 0
        self.started = time.time()
        self.error: Optional[str] = None
        self.result: Optional[dict] = None
        self.cancel = threading.Event()

    def to_dict(self):
        return {"id": self.id, "kind": self.kind, "state": self.state, "phase": self.phase,
                "tokens": self.tokens, "step": self.step, "total_steps": self.total_steps,
                "elapsed": round(time.time() - self.started, 1), "error": self.error,
                "result": self.result}


def start_job(kind: str, work) -> dict:
    job = Job(kind)
    _jobs[job.id] = job

    def run():
        with _run_lock:
            if job.cancel.is_set():
                job.state = "cancelled"
                return
            job.state = "running"
            try:
                job.result = work(job)
                job.state, job.phase = "done", "Done"
            except InterruptedError:
                job.state, job.phase = "cancelled", "Cancelled"
            except Exception as exc:  # noqa: BLE001 — surfaced to the app verbatim
                traceback.print_exc()
                job.state, job.error = "error", f"{type(exc).__name__}: {exc}"
            finally:
                mx.clear_cache()

    threading.Thread(target=run, daemon=True).start()
    return job.to_dict()


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------

class GenerateRequest(BaseModel):
    style: str
    lyrics: str
    cot: Literal["full", "melody", "off"] = "full"
    steps: int = Field(16, ge=1, le=64)
    seed: int = Field(42, ge=0)
    abc: Optional[str] = None
    instrumental: bool = False


def validate(req: GenerateRequest):
    style, lyrics = req.style.strip(), req.lyrics.strip()
    if not style:
        raise HTTPException(400, "Describe the musical style.")
    if not lyrics:
        if not req.instrumental:
            raise HTTPException(400, "Enter lyrics with section labels such as [Verse] and [Chorus].")
        lyrics = "[instrumental]"   # LoRA's "bare" caption: the model picks structure and length
    if len(style) > 1_000:
        raise HTTPException(400, "Keep the style prompt under 1,000 characters.")
    if len(lyrics) > 12_000:
        raise HTTPException(400, "Keep the lyrics under 12,000 characters.")
    abc = (req.abc or "").strip() or None
    if abc is not None and len(abc) > 100_000:
        raise HTTPException(400, "Keep the ABC score under 100,000 characters.")
    return style, lyrics, abc


def generate_work(req: GenerateRequest, style: str, lyrics: str, abc: Optional[str]):
    def work(job: Job):
        from lyra.nar import synthesize
        job.phase = "Loading model"
        pipe = get_pipe()
        lora = set_instrumental(pipe, req.instrumental)
        pipe.generation_config = replace(pipe.generation_config, ode_steps=req.steps)
        cancelled = job.cancel.is_set
        cot = "melody" if abc else req.cot

        def on_token(phase, _token):
            job.tokens += 1

        t0 = time.perf_counter()
        job.phase = "Using provided score" if abc else ("Planning score" if cot != "off" else "Generating song")
        plan = pipe.plan(style=style, lyrics=lyrics, cot=cot, seed=req.seed, abc=abc,
                         cancelled=cancelled, on_token=on_token)
        t_plan = time.perf_counter()
        job.phase, job.tokens = "Generating song", 0
        semantic = pipe.generate_semantic(plan, cancelled=cancelled, on_token=on_token)
        t_semantic = time.perf_counter()

        # Same as pipe.synthesize() for the MLX backend, but with step progress.
        job.phase, job.total_steps = "Synthesizing audio", 0
        model = pipe._load_model(for_nar=True)

        def on_progress(done, total):
            job.step, job.total_steps = done, total

        latents = synthesize(model, plan.prefix, semantic.tokens, req.seed,
                             steps=pipe.generation_config.ode_steps,
                             context=pipe.generation_config.context,
                             cancelled=cancelled, on_progress=on_progress,
                             query_chunk_size=pipe.query_chunk_size)
        if job.cancel.is_set():
            raise InterruptedError
        t_nar = time.perf_counter()
        job.phase = "Decoding audio"
        audio = pipe.decode(latents)
        t_decode = time.perf_counter()

        job.phase = "Saving"
        out = OUTPUT_ROOT / f"{datetime.now():%Y%m%d-%H%M%S}-{job.kind}-{req.seed}"
        out.mkdir(parents=True, exist_ok=True)
        import soundfile as sf
        flac = out / "song.flac"
        sf.write(flac, audio, 48000, subtype="PCM_24")
        mp3 = out / "song.mp3"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(flac),
                        "-codec:a", "libmp3lame", "-b:a", "192k", str(mp3)],
                       check=True, capture_output=True, text=True)
        score = plan.abc or ""
        if score:
            (out / "score.abc").write_text(score)
        (out / "lyrics.txt").write_text(lyrics)
        (out / "style.txt").write_text(style)
        result = {"flac": str(flac), "mp3": str(mp3), "abc": score,
                  "audio_seconds": round(len(audio) / 48000, 2),
                  "seconds": round(time.perf_counter() - t0, 1),
                  "truncated": plan.truncated or semantic.truncated,
                  "timing": {"abc": plan.timing, "semantic": semantic.timing}}
        stages = {"plan": t_plan - t0, "semantic": t_semantic - t_plan,
                  "nar": t_nar - t_semantic, "decode": t_decode - t_nar}
        (out / "timing.json").write_text(json.dumps(
            {"backend": f"{pipe.backend}-{pipe.precision}", "cot": cot, "steps": req.steps,
             "instrumental": req.instrumental, "instrumental_lora": lora,
             "audio_seconds": result["audio_seconds"], "seconds": result["seconds"],
             "truncated": result["truncated"], "stages": {k: round(v, 1) for k, v in stages.items()},
             "timing": result["timing"]}, indent=2, default=str))
        return result
    return work


@app.post("/generate")
def generate(req: GenerateRequest):
    style, lyrics, abc = validate(req)
    kind = "cover" if abc else "song"
    return start_job(kind, generate_work(req, style, lyrics, abc))


# --------------------------------------------------------------------------
# Cover source transcription (melody ABC via SheetSage2)
# --------------------------------------------------------------------------

class TranscribeRequest(BaseModel):
    path: str


@app.post("/transcribe")
def transcribe(req: TranscribeRequest):
    path = Path(req.path).expanduser()
    if not path.is_file():
        raise HTTPException(400, f"Source file not found: {path}")

    def work(job: Job):
        from lyra.transcription.pipeline import transcribe as sheetsage_transcribe
        job.phase = "Loading SheetSage2"
        model = get_transcriber()
        job.phase = "Transcribing melody"

        def on_progress(info):
            if info.get("stage") == "encoding":
                job.step, job.total_steps = info["window"], info["windows"]

        with tempfile.TemporaryDirectory(prefix="yue2-transcribe-") as tmp:
            result = sheetsage_transcribe(path, Path(tmp) / "out", model=model, offline=True,
                                          task="melody-full", cancelled=job.cancel.is_set,
                                          progress=on_progress)
        abc = result.get("abc")
        if not abc:
            raise RuntimeError("SheetSage2 did not produce an ABC score for this audio.")
        return {"abc": abc}

    return start_job("transcribe", work)


# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------

@app.get("/health")
def health():
    return {"status": "ok", "device": DEVICE, "model_loaded": _pipe is not None,
            "transcriber_loaded": _transcriber is not None, "busy": _run_lock.locked(),
            "instrumental_lora": instrumental_lora_path() is not None}


@app.get("/jobs/{job_id}")
def job_status(job_id: str):
    job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Unknown job")
    return job.to_dict()


@app.post("/jobs/{job_id}/cancel")
def job_cancel(job_id: str):
    job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "Unknown job")
    job.cancel.set()
    return job.to_dict()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8810)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
