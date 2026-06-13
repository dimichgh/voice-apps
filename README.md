# MLX Local AI Stack — MacBook Pro M5 / 128GB

Three thin scripts to bootstrap, manage, and benchmark MLX-native AI on Apple Silicon.
Recommendations are seeded from an adversarial deep-research pass (June 2026) — 20/25 claims survived 3-vote verification across 25 sources.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Create `.venv`, install `mlx`, `mlx-lm`, `mlx-vlm`, `mlx-audio`, `mlx-tune`; clone MLX-native video repos into `ext/`. |
| `mlxmgr.py` | Single-file CLI for the catalog: list / show / install / remove / disk / search / run / bench. |
| `bench.py`  | Measure prefill + decode tok/s (LLM), TTS real-time factor (voice), wall-clock for 5-second clips (video). |

## Quickstart

```bash
./install.sh                              # bootstrap venv + MLX stack
source .venv/bin/activate
./mlxmgr.py list                          # see the catalog
./mlxmgr.py install omnivoice             # default TTS pick
./mlxmgr.py install qwen3-coder-30b-a3b-4bit
./mlxmgr.py install ltx2-mlx              # MLX-native LTX-2.3 video
./mlxmgr.py run omnivoice --text "hello world"
./bench.py --quick                        # run benchmarks on installed models
```

## Verified recommendations (June 2026)

### LLM — `mlx-lm`
- **Coding default:** Qwen3-Coder MoE 30B-A3B @ 4-bit (~17GB) — `qwen3-coder-30b-a3b-4bit`.
- **Flagship (won't fit 128GB):** Qwen3-Coder 480B-A35B @ 4-bit MLX is **270GB** — M3 Ultra 256/512GB only.
- **M5 wins big on prefill** (3.33–4.06× vs M4) per [Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5). Decode is bandwidth-bound (19–27% faster).

### Voice — `mlx-audio`
- **Default:** [OmniVoice](https://github.com/k2-fsa/OmniVoice) 0.6B — 646+ languages, zero-shot cloning, voice design. MLX port at `mlx-community/OmniVoice-bf16`.
- **Expressive runner-up:** Higgs Audio v3 (4B, 100 langs, inline control tokens) at `bosonai/higgs-audio-v3-tts-4b`.
- **Editing (paralinguistics):** [Step-Audio-EditX](https://github.com/stepfun-ai/Step-Audio-EditX) 3B — best in class but **PyTorch-MPS only**, no MLX port yet.
- **Fine-tuning:** [mlx-tune](https://github.com/ARahim3/mlx-tune) — SFT/DPO/GRPO on TTS, STT, LLMs with Unsloth-compatible API.

### Video — MLX-native ports
- **Default at 128GB:** [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx) — Lightricks LTX-2.3 pure MLX. bf16 (~42GB) / int8 / int4. T2V with stereo audio, I2V, A2V, keyframe interpolation, IC-LoRA. Tiling for HD/4K via `--low-ram --tile-frames N`.
- **Runner-up:** [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video) — broader catalogue (LTX-2 19B, Wan2.1 1.3B/14B, Wan2.2 T2V-14B/TI2V-5B/I2V-14B), joint audio-video, LoRA finetuning.

## What the research could *not* confirm

Two specific tok/s claims were refuted under adversarial verification (Llama 5 70B @ 18 tok/s on M5 Max; Qwen 3.6-35B-A3B @ 55 tok/s). Run `./bench.py` to get honest numbers for *your* machine. Open questions to close locally:
- Practical tok/s on 128GB M5 (not 24GB M5) across 4/6/8-bit
- Best sub-480B Qwen3-Coder SKU for SWE-Bench / agentic coding
- LTX-2.3 bf16 / Wan2.2 14B wall-clock for 5-second 720p generation

## Extending the catalog

`mlxmgr.py`'s `CATALOG` is plain Python — add an `Entry(...)` and rerun. Use `verified=False` for repos you haven't confirmed exist; the `?` marker in `list` keeps you honest.

`./mlxmgr.py search qwen3` queries HuggingFace for live `mlx-community/*` repos so you can discover newer ports.

## Layout

```
.venv/                  Python virtualenv (created by install.sh)
ext/                    cloned MLX-native repos (mlx-video, ltx-2-mlx)
mlxmgr.py               model manager CLI
bench.py                benchmark harness
install.sh              bootstrap script
~/.cache/huggingface/   weights cache (shared with mlx-lm / mlx-audio)
```
