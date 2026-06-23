#!/usr/bin/env python3
"""mlxmgr — manage MLX-native local AI models on Apple Silicon (M5 target).

Subcommands:
  list                  show catalog + install state
  show <slug>           details for one entry
  install <slug>        snapshot_download into HF cache
  remove <slug>         delete the snapshot
  run <slug> ...        invoke the right runtime with the model
  disk                  HF cache size per cached repo
  search <query>        live HuggingFace search restricted to mlx-community
  bench <slug>          shortcut to bench.py for this model

Designed to be edited. The CATALOG dict below is the source of truth — add
entries as new MLX ports land. Keep `verified` honest: True only if the
research workflow or your own run confirmed the repo exists.
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
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

HOME = Path.home()
HF_CACHE = Path(os.environ.get("HF_HOME", HOME / ".cache" / "huggingface")) / "hub"
ROOT = Path(__file__).resolve().parent
EXT = ROOT / "ext"


@dataclass
class Entry:
    slug: str
    category: str          # "llm" | "image" | "voice" | "video"
    kind: str              # "hf" | "git"
    repo: str              # HF repo id, or git URL for kind=git
    runner: str            # "mlx_lm" | "mlx_vlm" | "mlx_audio" | "mflux" |
                           # "mlx_video" | "mlx_video_hf" | "ltx2" | "git-readme"
    approx_gb: float       # rough on-disk footprint in GB
    fits_128gb: bool       # honest assessment for 128GB unified memory
    description: str
    verified: bool = False # confirmed by research / personal run
    notes: str = ""
    tags: list[str] = field(default_factory=list)
    entrypoint: str = ""   # mflux console script (e.g. "mflux-generate-ideogram4")
                           # or mlx_video submodule (e.g. "mlx_video.wan_2.generate")


CATALOG: dict[str, Entry] = {e.slug: e for e in [
    # ------ LLMs -----------------------------------------------------------
    Entry(
        slug="qwen3-coder-480b-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-480B-A35B-Instruct-4bit",
        runner="mlx_lm",
        approx_gb=270.0,
        fits_128gb=False,
        verified=True,
        description="Qwen3-Coder 480B MoE (35B active) — flagship coding model, ~Claude Sonnet on agentic coding per Qwen.",
        notes="Does NOT fit 128GB. Listed for M3 Ultra 256/512GB owners.",
        tags=["coding", "agentic", "moe"],
    ),
    Entry(
        slug="qwen3-coder-next-8bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-Next-8bit",
        runner="mlx_lm",
        approx_gb=84.7,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Coder-Next 8-bit — newest agentic coding flagship from Qwen, near-bf16 quality. Top quality pick for 128GB.",
        notes="bf16 variant is 159GB and does NOT fit; use 8bit or 6bit on 128GB.",
        tags=["coding", "agentic", "flagship"],
    ),
    Entry(
        slug="qwen3-coder-next-6bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-Next-6bit",
        runner="mlx_lm",
        approx_gb=64.7,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Coder-Next 6-bit — sweet spot on 128GB: newest model, faster decode than 8bit, ~60GB free for KV cache / huge context.",
        tags=["coding", "agentic", "balanced"],
    ),
    Entry(
        slug="qwen3-coder-next-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-Next-4bit",
        runner="mlx_lm",
        approx_gb=44.8,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Coder-Next 4-bit — fastest of the Next family. Use when you want the new architecture with maximum decode speed.",
        tags=["coding", "agentic", "fast"],
    ),
    Entry(
        slug="qwen3-coder-30b-a3b-dwq",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2",
        runner="mlx_lm",
        approx_gb=17.2,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Coder 30B-A3B MoE @ 4-bit DWQ (data-aware quant) — battle-tested daily driver. Reported ~230 tok/s on M5 Max.",
        notes="DWQ-v2 quality is closer to 6-bit at 4-bit size. Best for inline editor completion / fast autocomplete.",
        tags=["coding", "moe", "fast", "dwq"],
    ),
    Entry(
        slug="qwen3-coder-30b-a3b-8bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
        runner="mlx_lm",
        approx_gb=32.4,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Coder 30B-A3B MoE at 8-bit — proven safe pick. Use if you want the mature variant without surprises.",
        tags=["coding", "moe", "hi-quality"],
    ),
    Entry(
        slug="gemma-4-12b-it-8bit",
        category="llm",
        kind="hf",
        repo="mlx-community/gemma-4-12B-it-8bit",
        runner="mlx_vlm",
        approx_gb=14.0,
        fits_128gb=True,
        verified=True,
        description="Gemma 4 12B INSTRUCT at 8-bit — chat-tuned (has chat template + tool-calling), highest-fidelity instruct short of bf16. The pick for the voice assistant.",
        notes="Unlike gemma-4-12B-8bit (base/pretrained, no chat template), this is the -it instruct model. Runner mlx_vlm (unified multimodal).",
        tags=["multimodal", "vision", "audio-in", "instruct", "tools", "hi-quality"],
    ),
    Entry(
        slug="gemma-4-12b-it-qat-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/gemma-4-12B-it-qat-4bit",
        runner="mlx_vlm",
        approx_gb=7.0,
        fits_128gb=True,
        verified=True,
        description="Gemma 4 12B Instruct, QAT 4-bit — unified multimodal (text/image/audio→text), 256K ctx. Best quality-per-bit thanks to quantization-aware training.",
        notes="Released June 3 2026, Apache 2.0. For image/audio inputs use mlx-vlm rather than the mlx-lm runner.",
        tags=["multimodal", "vision", "audio-in", "qat"],
    ),
    Entry(
        slug="gemma-4-12b-it-optiq-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/gemma-4-12B-it-OptiQ-4bit",
        runner="mlx_vlm",
        approx_gb=7.0,
        fits_128gb=True,
        verified=True,
        description="Gemma 4 12B Instruct, OptiQ mixed-precision 4-bit — sensitivity-aware quant via mlx-optiq.",
        tags=["multimodal", "vision", "audio-in", "optiq"],
    ),
    Entry(
        slug="gemma-4-12b-8bit",
        category="llm",
        kind="hf",
        repo="mlx-community/gemma-4-12B-8bit",
        runner="mlx_vlm",
        approx_gb=14.0,
        fits_128gb=True,
        verified=True,
        description="Gemma 4 12B at 8-bit — higher fidelity, ~2x memory of 4-bit. Use when quality matters more than speed.",
        tags=["multimodal", "hi-quality"],
    ),
    Entry(
        slug="qwen3-235b-thinking-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-235B-A22B-Thinking-4bit",
        runner="mlx_lm",
        approx_gb=130.0,
        fits_128gb=False,
        verified=False,
        description="Qwen3 235B MoE reasoning model — borderline for 128GB even at 4-bit; KV will spill.",
        notes="Try only with tiny context. Probably needs M3 Ultra in practice.",
        tags=["reasoning", "moe"],
    ),
    Entry(
        slug="qwen3-omni-30b-a3b-4bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Omni-30B-A3B-Instruct-4bit",
        runner="mlx_vlm",
        approx_gb=21.8,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Omni 30B-A3B MoE @ 4-bit — text/image/audio/video → text, 119 langs, native <tool_call> function calling. Fast decode.",
        notes="Audio-in works via mlx-vlm. Talker (24kHz speech-out) is NOT in the MLX port yet — pair with Kokoro/OmniVoice for voice replies.",
        tags=["multimodal", "audio-in", "vision", "tools", "moe", "fast"],
    ),
    Entry(
        slug="qwen3-omni-30b-a3b-6bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Omni-30B-A3B-Instruct-6bit",
        runner="mlx_vlm",
        approx_gb=30.0,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Omni 30B-A3B @ 6-bit — best quality/speed tradeoff. Closer to bf16 output than 4-bit.",
        notes="Same audio-out caveat as the 4-bit entry. Use Kokoro for TTS sidecar.",
        tags=["multimodal", "audio-in", "vision", "tools", "moe", "balanced"],
    ),
    Entry(
        slug="qwen3-omni-30b-a3b-8bit",
        category="llm",
        kind="hf",
        repo="mlx-community/Qwen3-Omni-30B-A3B-Instruct-8bit",
        runner="mlx_vlm",
        approx_gb=38.0,
        fits_128gb=True,
        verified=True,
        description="Qwen3-Omni 30B-A3B @ 8-bit — highest quality short of bf16. Pick for serious agentic / tool-calling voice work.",
        notes="Used by voicechat-mac. Audio-in via mlx-vlm; speech-out via Kokoro sidecar through omlx /v1/audio/speech.",
        tags=["multimodal", "audio-in", "vision", "tools", "moe", "hi-quality"],
    ),
    # ------ Image (text-to-image, runtime = mflux >=0.18) ------------------
    # mflux uses a uniform `--model <hf-repo>` auto-download interface across
    # per-architecture console scripts (mflux-generate-ideogram4/-qwen/-flux2/
    # -z-image-turbo...). Install once: `.venv/bin/pip install -U mflux`.
    Entry(
        slug="ideogram-4-q8",
        category="image",
        kind="hf",
        repo="MLXBits/ideogram-4-mlx-q8",
        runner="mflux",
        entrypoint="mflux-generate-ideogram4",
        approx_gb=28.5,
        fits_128gb=True,
        verified=True,
        description="Ideogram 4 @ 8-bit (mflux) — best-in-class TYPOGRAPHY / text-in-image and design layouts. The pick when the image needs legible words.",
        notes="RUN-VERIFIED via mlxmgr (peak ~31.7GB MLX mem; 20-step preset ~2:20, 12-step TURBO ~1:25; headline text crisp). REQUIRES mflux from PR #445 (`.venv/bin/pip install --force-reinstall --no-deps git+https://github.com/plz12345/mflux.git@ideogram-mlx-forge-loader-pr`) — STOCK pip mflux 0.18.0 rejects the int8 mlx-forge layout ('requires FP8 checkpoint layout'). GATED + NON-COMMERCIAL: accept the agreement on HF + be logged in. Preset-driven: --preset V4_DEFAULT_20|V4_QUALITY_48|V4_TURBO_12 (--steps ignored). Prompt tip: trained on structured JSON captions — plain text degrades small/secondary text.",
        tags=["text-to-image", "typography", "design", "gated", "non-commercial"],
    ),
    Entry(
        slug="ideogram-4-q4",
        category="image",
        kind="hf",
        repo="MLXBits/ideogram-4-mlx-q4",
        runner="mflux",
        entrypoint="mflux-generate-ideogram4",
        approx_gb=15.8,
        fits_128gb=True,
        verified=True,
        description="Ideogram 4 @ 4-bit (mflux) — lighter/faster Ideogram 4 for quick typography iteration.",
        notes="Same gated non-commercial license + same mflux PR #445 branch requirement as ideogram-4-q8 (stock mflux won't load it). Full bf16 variant is MLXBits/ideogram-4-mlx (~52GB).",
        tags=["text-to-image", "typography", "gated", "non-commercial", "fast"],
    ),
    Entry(
        slug="qwen-image-2512-8bit",
        category="image",
        kind="hf",
        repo="mlx-community/Qwen-Image-2512-8bit",
        runner="mflux",
        entrypoint="mflux-generate-qwen",
        approx_gb=36.1,
        fits_128gb=True,
        verified=True,
        description="Qwen-Image 2512 @ 8-bit (mflux) — best all-round APACHE-2.0 general T2V: prompt adherence, world knowledge, strong text rendering. Default commercial-safe pick.",
        notes="Repo verified; run path not yet executed here (mflux-native qwen). 4-bit variant: mlx-community/Qwen-Image-2512-4bit (~26GB).",
        tags=["text-to-image", "general", "apache-2.0", "text-render"],
    ),
    Entry(
        slug="qwen-image-edit-2511-8bit",
        category="image",
        kind="hf",
        repo="mlx-community/qwen-image-edit-2511-8bit",
        runner="mflux",
        entrypoint="mflux-generate-qwen-edit",
        approx_gb=37.5,
        fits_128gb=True,
        verified=True,
        description="Qwen-Image-Edit 2511 @ 8-bit (mflux) — newest instruct image EDITING (multi-image), Apache-2.0. Pairs with qwen-image-2512 (one architecture = gen + edit).",
        notes="Edit runner takes --image-paths in.png --prompt '...'. Repo verified; run path not yet executed here.",
        tags=["image-edit", "instruct", "apache-2.0"],
    ),
    Entry(
        slug="flux2-klein-9b-8bit",
        category="image",
        kind="hf",
        repo="mlx-community/flux2-klein-9b-8bit",
        runner="mflux",
        entrypoint="mflux-generate-flux2",
        approx_gb=17.9,
        fits_128gb=True,
        verified=True,
        description="FLUX.2 Klein 9B @ 8-bit (mflux) — modern DiT quality/edit workhorse, Apache-2.0. Lighter than Qwen-Image, supports edit via mflux-generate-flux2-edit.",
        notes="Repo verified; run path not yet executed here. 4-bit: mlx-community/flux2-klein-9b-4bit (~10GB). FLUX.2-dev (flagship) has no MLX port yet — only Klein.",
        tags=["text-to-image", "flux", "apache-2.0", "edit"],
    ),
    Entry(
        slug="z-image-turbo-q8",
        category="image",
        kind="hf",
        repo="deepsweet/Z-Image-Turbo-6B-MLX-Q8",
        runner="mflux",
        entrypoint="mflux-generate-z-image-turbo",
        approx_gb=20.5,
        fits_128gb=True,
        verified=True,
        description="Z-Image-Turbo 6B @ 8-bit (mflux) — fast few-step realism, Apache-2.0. The quick-iteration / photoreal pick.",
        notes="RUN-VERIFIED end-to-end via mlxmgr: 25 steps ~67s, peak 13.9GB MLX mem, clean photoreal output. Repo is ~20.5GB on disk (bundles fp text encoder). 4-bit: deepsweet/Z-Image-Turbo-6B-MLX-Q4 (~6GB).",
        tags=["text-to-image", "fast", "photoreal", "apache-2.0", "turbo"],
    ),
    # ------ Voice ----------------------------------------------------------
    Entry(
        slug="omnivoice",
        category="voice",
        kind="hf",
        repo="mlx-community/OmniVoice-bf16",
        runner="mlx_audio",
        approx_gb=2.0,
        fits_128gb=True,
        verified=True,
        description="OmniVoice 0.6B, 646+ languages, zero-shot voice cloning + voice design. Default TTS pick.",
        notes="k2-fsa, Apache 2.0, released March 2026. MLX port by Blaizzy/mlx-audio.",
        tags=["tts", "clone", "multilingual"],
    ),
    Entry(
        slug="higgs-audio-v3",
        category="voice",
        kind="hf",
        repo="bosonai/higgs-audio-v3-tts-4b",
        runner="mlx_audio",
        approx_gb=9.0,
        fits_128gb=True,
        verified=True,
        description="Higgs Audio v3 4B — expressive conversational TTS with voice cloning + inline control tokens, 100 languages.",
        tags=["tts", "expressive", "clone"],
    ),
    Entry(
        slug="whisper-large-v3-turbo-asr-fp16",
        category="voice",
        kind="hf",
        repo="mlx-community/whisper-large-v3-turbo-asr-fp16",
        runner="mlx_audio",
        approx_gb=1.6,
        fits_128gb=True,
        verified=True,
        description="Whisper large-v3-turbo ASR (fp16, MLX) — speech→text. Served via omlx for the voicechat/voicedub/murmur apps.",
        notes="ASR/STT, not TTS — invoked through the omlx server's /v1/audio/transcriptions, not `mlxmgr run`. The omlx apps reference it as mlx-community--whisper-large-v3-turbo-asr-fp16.",
        tags=["asr", "stt", "whisper", "omlx"],
    ),
    Entry(
        slug="kokoro",
        category="voice",
        kind="hf",
        repo="prince-canuma/Kokoro-82M",
        runner="mlx_audio",
        approx_gb=0.3,
        fits_128gb=True,
        verified=False,
        description="Kokoro 82M — tiny, fast English TTS via mlx-audio. Great for low-latency UI voices.",
        tags=["tts", "fast", "tiny"],
    ),
    Entry(
        slug="csm-sesame",
        category="voice",
        kind="hf",
        repo="mlx-community/csm-1b",
        runner="mlx_audio",
        approx_gb=2.5,
        fits_128gb=True,
        verified=False,
        description="Sesame CSM conversational speech model via mlx-audio.",
        tags=["tts", "conversational"],
    ),
    Entry(
        slug="voxcpm2",
        category="voice",
        kind="hf",
        repo="mlx-community/VoxCPM2-bf16",
        runner="mlx_audio",
        approx_gb=4.0,
        fits_128gb=True,
        verified=True,
        description="VoxCPM2 2B (OpenBMB) — 30-language TTS, 48kHz studio quality, voice cloning + voice design from text descriptions, 4 generation modes. bf16 full-precision.",
        notes="Smaller variants exist: mlx-community/VoxCPM2-8bit (~2x faster, 35% smaller) and VoxCPM2-4bit. On 128GB use bf16 unless you need decode speed.",
        tags=["tts", "clone", "voice-design", "multilingual", "48khz"],
    ),
    Entry(
        slug="voxcpm2-8bit",
        category="voice",
        kind="hf",
        repo="mlx-community/VoxCPM2-8bit",
        runner="mlx_audio",
        approx_gb=2.5,
        fits_128gb=True,
        verified=True,
        description="VoxCPM2 8-bit — best quality/speed tradeoff per mlx-community, ~2x faster than bf16.",
        tags=["tts", "clone", "voice-design", "fast"],
    ),
    Entry(
        slug="step-audio-editx",
        category="voice",
        kind="git",
        repo="https://github.com/stepfun-ai/Step-Audio-EditX.git",
        runner="git-readme",
        approx_gb=8.0,
        fits_128gb=True,
        verified=True,
        description="Step-Audio-EditX 3B — best open paralinguistic editor (emotion / whisper / breathing / laughter). PyTorch-MPS only, no MLX port yet.",
        notes="On M5 this runs via PyTorch-MPS, not Metal TensorOps — slower than MLX-native voice.",
        tags=["edit", "paralinguistic", "mps-only"],
    ),
    # ------ Video ----------------------------------------------------------
    Entry(
        slug="ltx2-mlx",
        category="video",
        kind="git",
        repo="https://github.com/dgrauet/ltx-2-mlx.git",
        runner="ltx2",
        approx_gb=42.0,
        fits_128gb=True,
        verified=True,
        description="LTX-2.3 pure MLX port — T2V/I2V/A2V with stereo 48kHz audio, keyframe interp, IC-LoRA, tiling for HD/4K on 128GB. bf16 ~42GB / int8 ~21GB / int4 ~12GB.",
        notes="Recommended default video pick at 128GB. Use --low-ram + --tile-frames for 4K.",
        tags=["t2v", "i2v", "audio", "tiling"],
    ),
    Entry(
        slug="mlx-video",
        category="video",
        kind="git",
        repo="https://github.com/Blaizzy/mlx-video.git",
        runner="mlx_video",
        approx_gb=40.0,
        fits_128gb=True,
        verified=True,
        description="MLX-Video — multi-model toolkit: LTX-2 19B, Wan2.1 (1.3B/14B T2V), Wan2.2 (T2V-14B, TI2V-5B, I2V-14B). Joint audio-video, LoRA finetuning.",
        notes="Weights pulled per-model; size depends on which Wan/LTX variant you generate with. Real submodules are mlx_video.ltx_2.generate (--model-repo) and mlx_video.wan_2.generate (--model-dir) — NOT mlx_video.generate.",
        tags=["t2v", "i2v", "a2v", "wan", "ltx", "lora"],
    ),
    Entry(
        slug="wan22-ti2v-5b",
        category="video",
        kind="hf",
        repo="SceneWorks/wan2.2-ti2v-5b-mlx",
        runner="mlx_video_hf",
        entrypoint="mlx_video.models.wan_2.generate",
        approx_gb=24.0,
        fits_128gb=True,
        verified=True,
        description="Wan 2.2 TI2V-5B (MLX) — fast, low-memory Apache-2.0 video: does BOTH T2V and I2V from one 5B model. Cleanest-license daily driver; no audio.",
        notes="RUN-VERIFIED via mlxmgr: 13-frame 832x480 20-step clip in ~46s, ~30GB+ RAM stayed free. ~24GB on disk (model 10 + t5 11 + vae 3). MEMORY WARNING: the default 1280x704 + many frames + NO tiling can OOM 128GB (caused a crash) — always pass --tiling auto and keep --num-frames modest (must be 4n+1). I2V: add --image in.png.",
        tags=["t2v", "i2v", "wan", "apache-2.0", "fast"],
    ),
    Entry(
        slug="wan22-t2v-a14b",
        category="video",
        kind="hf",
        repo="SceneWorks/wan2.2-t2v-a14b-mlx",
        runner="mlx_video_hf",
        entrypoint="mlx_video.models.wan_2.generate",
        approx_gb=56.0,
        fits_128gb=True,
        verified=True,
        description="Wan 2.2 T2V-A14B (MLX) — highest-fidelity silent T2V, 2x14B MoE (~28B resident at int8). Apache-2.0. 128GB is one of the few machines that runs it at bf16.",
        notes="bf16 ~56GB / int8 ~28GB (est). MoE loads high_noise + low_noise models. No audio. Repo verified; run-path untested here.",
        tags=["t2v", "wan", "moe", "apache-2.0", "hi-quality"],
    ),
    Entry(
        slug="wan22-i2v-a14b",
        category="video",
        kind="hf",
        repo="SceneWorks/wan2.2-i2v-a14b-mlx",
        runner="mlx_video_hf",
        entrypoint="mlx_video.models.wan_2.generate",
        approx_gb=56.0,
        fits_128gb=True,
        verified=True,
        description="Wan 2.2 I2V-A14B (MLX) — highest-fidelity image-to-video, 2x14B MoE. Apache-2.0, no audio. Animate a still at top quality.",
        notes="bf16 ~56GB / int8 ~28GB (est). Repo verified; run-path untested here.",
        tags=["i2v", "wan", "moe", "apache-2.0", "hi-quality"],
    ),
    Entry(
        slug="longcat-video-q8",
        category="video",
        kind="hf",
        repo="mlx-community/LongCat-Video-q8",
        runner="mlx_video_hf",
        entrypoint="mlx_video.models.ltx_2.generate",
        approx_gb=14.0,
        fits_128gb=True,
        verified=True,
        description="LongCat-Video 13.6B @ 8-bit (MLX) — LONG-FORM specialist: minutes-long 720p/30fps via native video-continuation. MIT license (most permissive). No audio.",
        notes="bf16 variant: mlx-community/LongCat-Video-bf16. Runtime/runner for LongCat is unconfirmed (listed mlx_video.ltx_2 as a guess) — verify the correct generate path before relying on `run`. Repo verified.",
        tags=["t2v", "i2v", "long-form", "mit", "continuation"],
    ),
]}


# --------------------------------------------------------------------------
# State helpers
# --------------------------------------------------------------------------

def hf_snapshot_dir(repo: str) -> Path:
    """Path to a HuggingFace snapshot directory in the local cache."""
    return HF_CACHE / ("models--" + repo.replace("/", "--"))


def installed(entry: Entry) -> bool:
    if entry.kind == "hf":
        return hf_snapshot_dir(entry.repo).exists()
    if entry.kind == "git":
        return (EXT / Path(entry.repo).stem).exists()
    return False


def disk_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for p in path.rglob("*"):
        try:
            total += p.stat().st_size if p.is_file() else 0
        except OSError:
            pass
    return total


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

def cmd_list(args: argparse.Namespace) -> int:
    by_cat: dict[str, list[Entry]] = {}
    for e in CATALOG.values():
        by_cat.setdefault(e.category, []).append(e)

    for cat in ("llm", "image", "voice", "video"):
        if cat not in by_cat:
            continue
        print(f"\n=== {cat.upper()} ===")
        for e in sorted(by_cat[cat], key=lambda x: x.slug):
            mark = "✓" if installed(e) else " "
            fits = "  " if e.fits_128gb else "!!"
            verif = "✓" if e.verified else "?"
            print(f"  [{mark}] {fits} {verif} {e.slug:<28} {e.approx_gb:>6.1f}G  {e.description}")
    print("\nLegend: [✓]=installed  !!=does NOT fit 128GB  verified=research-confirmed (✓) vs guessed-repo (?)")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    e = CATALOG.get(args.slug)
    if not e:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    payload = {
        "slug": e.slug,
        "category": e.category,
        "kind": e.kind,
        "repo": e.repo,
        "runner": e.runner,
        "approx_gb": e.approx_gb,
        "fits_128gb": e.fits_128gb,
        "verified": e.verified,
        "installed": installed(e),
        "description": e.description,
        "notes": e.notes,
        "tags": e.tags,
    }
    if installed(e):
        path = hf_snapshot_dir(e.repo) if e.kind == "hf" else EXT / Path(e.repo).stem
        payload["path"] = str(path)
        payload["actual_size"] = human(disk_bytes(path))
    print(json.dumps(payload, indent=2))
    return 0


def cmd_install(args: argparse.Namespace) -> int:
    e = CATALOG.get(args.slug)
    if not e:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    if not e.fits_128gb and not args.force:
        print(f"refusing: {e.slug} approx {e.approx_gb}G — does not fit 128GB. Use --force to override.",
              file=sys.stderr)
        return 3
    if e.kind == "hf":
        try:
            from huggingface_hub import snapshot_download
        except ImportError:
            print("huggingface_hub not installed. Run ./install.sh first.", file=sys.stderr)
            return 4
        print(f"==> snapshot_download {e.repo}")
        snapshot_download(repo_id=e.repo)
        print(f"==> installed at {hf_snapshot_dir(e.repo)}")
    elif e.kind == "git":
        dest = EXT / Path(e.repo).stem.removesuffix(".git")
        EXT.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            print(f"==> updating {dest}")
            subprocess.check_call(["git", "-C", str(dest), "pull", "--ff-only"])
        else:
            print(f"==> git clone {e.repo} -> {dest}")
            subprocess.check_call(["git", "clone", "--depth", "1", e.repo, str(dest)])
        print(f"==> see {dest}/README.md for runtime-specific setup")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    e = CATALOG.get(args.slug)
    if not e:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    if e.kind == "hf":
        path = hf_snapshot_dir(e.repo)
    else:
        path = EXT / Path(e.repo).stem.removesuffix(".git")
    if not path.exists():
        print(f"not installed: {e.slug}")
        return 0
    if not args.yes:
        ans = input(f"delete {path} ({human(disk_bytes(path))})? [y/N] ").strip().lower()
        if ans != "y":
            print("aborted")
            return 1
    shutil.rmtree(path)
    print(f"removed {path}")
    return 0


def cmd_disk(args: argparse.Namespace) -> int:
    rows = []
    for e in CATALOG.values():
        if e.kind == "hf":
            path = hf_snapshot_dir(e.repo)
        else:
            path = EXT / Path(e.repo).stem.removesuffix(".git")
        if path.exists():
            rows.append((human(disk_bytes(path)), e.slug, str(path)))
    rows.sort(key=lambda r: r[1])
    if not rows:
        print("no models installed")
        return 0
    for size, slug, path in rows:
        print(f"{size:>10}  {slug:<28}  {path}")
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    """Live HF search restricted to mlx-community author."""
    q = " ".join(args.query)
    url = "https://huggingface.co/api/models?" + urllib.parse.urlencode({
        "author": "mlx-community",
        "search": q,
        "limit": "30",
        "sort": "downloads",
        "direction": "-1",
    })
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            data = json.load(r)
    except urllib.error.URLError as exc:
        print(f"search failed: {exc}", file=sys.stderr)
        return 1
    for m in data:
        print(f"  {m['id']:<60}  ↓{m.get('downloads', 0)}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    e = CATALOG.get(args.slug)
    if not e:
        print(f"unknown slug: {args.slug}", file=sys.stderr)
        return 2
    if not installed(e):
        print(f"not installed. Run: mlxmgr install {e.slug}", file=sys.stderr)
        return 3
    extra = args.extra or []
    if e.runner == "mlx_lm":
        cmd = [sys.executable, "-m", "mlx_lm.generate", "--model", e.repo, *extra]
    elif e.runner == "mlx_vlm":
        cmd = [sys.executable, "-m", "mlx_vlm.generate", "--model", e.repo, *extra]
    elif e.runner == "mlx_audio":
        cmd = [sys.executable, "-m", "mlx_audio.tts.generate", "--model", e.repo, *extra]
    elif e.runner == "mflux":
        # mflux ships per-architecture console scripts in the venv's bin dir.
        # Uniform interface: <script> --model <hf-repo> (auto-downloads).
        exe = Path(sys.executable).parent / e.entrypoint
        exe = str(exe) if exe.exists() else e.entrypoint
        cmd = [exe, "--model", e.repo, *extra]
    elif e.runner == "mlx_video_hf":
        # Installed mlx_video package + HF-cached weights. Wan wants a local
        # --model-dir; LTX-family wants --model-repo (auto-download).
        if "wan_2" in e.entrypoint:
            try:
                from huggingface_hub import snapshot_download
                weights = ["--model-dir", snapshot_download(repo_id=e.repo)]
            except Exception as exc:  # noqa: BLE001
                print(f"could not resolve weights dir: {exc}", file=sys.stderr)
                return 5
        else:
            weights = ["--model-repo", e.repo]
        cmd = [sys.executable, "-m", e.entrypoint, *weights, *extra]
    elif e.runner == "mlx_video":
        dest = EXT / Path(e.repo).stem.removesuffix(".git")
        cmd = [sys.executable, "-m", "mlx_video.generate", *extra]
        return _run_in_dir(cmd, dest)
    elif e.runner == "ltx2":
        dest = EXT / Path(e.repo).stem.removesuffix(".git")
        cmd = [sys.executable, "-m", "ltx2.generate", *extra]
        return _run_in_dir(cmd, dest)
    elif e.runner == "git-readme":
        dest = EXT / Path(e.repo).stem.removesuffix(".git")
        print(f"This model has no MLX runner. See {dest}/README.md for invocation.")
        return 0
    else:
        print(f"unknown runner: {e.runner}", file=sys.stderr)
        return 4
    print(f"==> {' '.join(cmd)}")
    return subprocess.call(cmd)


def _run_in_dir(cmd: list[str], cwd: Path) -> int:
    print(f"==> (cd {cwd} && {' '.join(cmd)})")
    return subprocess.call(cmd, cwd=str(cwd))


def cmd_bench(args: argparse.Namespace) -> int:
    bench_script = ROOT / "bench.py"
    if not bench_script.exists():
        print("bench.py not found", file=sys.stderr)
        return 2
    return subprocess.call([sys.executable, str(bench_script), args.slug, *(args.extra or [])])


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mlxmgr", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list").set_defaults(func=cmd_list)

    s = sub.add_parser("show"); s.add_argument("slug"); s.set_defaults(func=cmd_show)

    s = sub.add_parser("install")
    s.add_argument("slug")
    s.add_argument("--force", action="store_true", help="install even if it won't fit 128GB")
    s.set_defaults(func=cmd_install)

    s = sub.add_parser("remove")
    s.add_argument("slug")
    s.add_argument("-y", "--yes", action="store_true")
    s.set_defaults(func=cmd_remove)

    sub.add_parser("disk").set_defaults(func=cmd_disk)

    s = sub.add_parser("search")
    s.add_argument("query", nargs="+")
    s.set_defaults(func=cmd_search)

    s = sub.add_parser("run")
    s.add_argument("slug")
    s.add_argument("extra", nargs=argparse.REMAINDER)
    s.set_defaults(func=cmd_run)

    s = sub.add_parser("bench")
    s.add_argument("slug")
    s.add_argument("extra", nargs=argparse.REMAINDER)
    s.set_defaults(func=cmd_bench)
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
