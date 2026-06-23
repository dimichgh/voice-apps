# Image & Video Generation — quick guide

Everything runs through `mlxmgr.py` on the M5 Max / 128GB. Three models are
already installed and **render-verified**: `ideogram-4-q8`, `z-image-turbo-q8`,
`wan22-ti2v-5b`.

General workflow:

```bash
python3 mlxmgr.py list                 # see catalog + [✓] installed state
python3 mlxmgr.py install <slug>       # download a model (Netskope-safe)
python3 mlxmgr.py run <slug> -- <args> # generate; extra args pass straight through
python3 mlxmgr.py show <slug>          # repo, size, path, notes
```

Outputs: pick a real path you control (e.g. `~/Desktop/...`). **Don't write to
`/tmp` — a reboot wipes it.**

---

## Image generation (runtime: mflux)

Flag for the output file is **`--output`**. Common pass-through flags:
`--height 1024 --width 1024 --seed 42 --steps N`.

### Fast photoreal — Z-Image-Turbo (installed, easiest)

```bash
python3 mlxmgr.py run z-image-turbo-q8 \
  --prompt "a red fox in autumn leaves, photorealistic, golden hour" \
  --output ~/Desktop/fox.png
# ~25 steps, ~70s, peak ~14GB. Runs on stock mflux.
```

### Typography / text-in-image — Ideogram 4 (installed)

Best model when the image must contain **legible words / signage / posters**.
Steps are preset-driven (`--steps` is ignored):

```bash
python3 mlxmgr.py run ideogram-4-q8 \
  --prompt "a vintage coffee shop sign reading 'MORNING BREW', warm light" \
  --preset V4_QUALITY_48 \
  --output ~/Desktop/sign.png
# presets: V4_TURBO_12 (fast ~1:25) | V4_DEFAULT_20 (~2:20) | V4_QUALITY_48 (best)
# peak ~32GB. GATED + NON-COMMERCIAL license.
```

Tip: Ideogram was trained on **structured JSON captions** — for clean *secondary*
text (menus, fine print), describe each text element explicitly; plain prose
nails the headline but garbles small text.

> ⚠️ Ideogram needs the mflux **PR #445** build (already installed here). Stock
> `pip install mflux` will NOT load it ("requires FP8 checkpoint layout"). To
> reinstall the branch:
> `.venv/bin/pip install --force-reinstall --no-deps git+https://github.com/plz12345/mflux.git@ideogram-mlx-forge-loader-pr`

### Other image models (repo-verified, run with one `install` first)

```bash
python3 mlxmgr.py install qwen-image-2512-8bit   # Apache-2.0 general pick (commercial-safe)
python3 mlxmgr.py run     qwen-image-2512-8bit --prompt "..." --output out.png

python3 mlxmgr.py install flux2-klein-9b-8bit    # modern DiT, lighter
python3 mlxmgr.py install z-image-turbo-q8        # already installed
```

Image **editing** (instruct, takes an input image):

```bash
python3 mlxmgr.py install qwen-image-edit-2511-8bit
python3 mlxmgr.py run     qwen-image-edit-2511-8bit \
  --image-paths in.png --prompt "make it night, add neon signs" --output out.png
```

---

## Video generation (runtime: mlx_video)

Flag for the output file is **`--output-path`** (note: different from image).

### Wan 2.2 TI2V-5B (installed) — does both T2V and I2V

> ⚠️ **OOM WARNING.** The default 1280×704 + many frames + no tiling **crashed the
> laptop**. Always pass `--tiling auto` and keep `--num-frames` small. Frame count
> must be **4n+1** (e.g. 13, 25, 49). Start small, scale up while watching memory.

Text-to-video:

```bash
python3 mlxmgr.py run wan22-ti2v-5b \
  --prompt "a calico kitten playing with a ball of yarn on a wooden floor" \
  --num-frames 13 --steps 20 --width 832 --height 480 --tiling auto \
  --output-path ~/Desktop/kitten.mp4
# verified: ~46s for this clip; RAM stayed >30GB free.
```

Image-to-video — same command, add `--image`:

```bash
python3 mlxmgr.py run wan22-ti2v-5b \
  --image ~/Desktop/photo.jpg --prompt "gentle camera push-in, leaves drifting" \
  --num-frames 13 --steps 20 --width 832 --height 480 --tiling auto \
  --output-path ~/Desktop/animated.mp4
```

### Other video models

- `ltx2-mlx` — LTX-2.3, the only one with **synchronized audio** + 4K/long clips.
- `wan22-t2v-a14b` / `wan22-i2v-a14b` — top-quality 2×14B MoE (~56GB bf16; heavy).
- `longcat-video-q8` — long-form (minutes), MIT license.

```bash
python3 mlxmgr.py install wan22-t2v-a14b   # then run as above (mind the memory)
```

---

## Memory cheat-sheet (128GB)

| Task | Peak | Safe? |
|---|---|---|
| z-image-turbo image | ~14GB | trivially |
| ideogram image | ~32GB | yes |
| wan ti2v-5b, 480p/13fr, **tiling** | <90GB | yes |
| wan ti2v-5b, 720p default, **no tiling** | >128GB | ❌ OOM — don't |

Inspect a frame of a video: `ffmpeg -i out.mp4 -vframes 1 frame.png`.
