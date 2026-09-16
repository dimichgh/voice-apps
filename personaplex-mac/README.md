# personaplex-mac

Native SwiftUI app for **PersonaPlex 7B** — NVIDIA's full-duplex speech-to-speech
model — running locally on Apple Silicon via MLX. Audio in, audio out, no
ASR→LLM→TTS cascade: it listens and speaks at the same time.

Forked from [`soniqo/speech-swift`](https://github.com/soniqo/speech-swift)'s
`Examples/PersonaPlexDemo` (Apache-2.0). Background, benchmarks and the
echo-cancellation situation are in [`../PERSONAPLEX.md`](../PERSONAPLEX.md).

## Setup

```bash
# 1. Weights (either or both; the app switches at runtime)
python3 mlxmgr.py install personaplex-mlx-8bit   # ~9.1 GB
python3 mlxmgr.py install personaplex-mlx-4bit   # ~5.4 GB

# 2. Metal toolchain, once — speech-swift compiles its own metallib
xcodebuild -downloadComponent MetalToolchain

# 3. Build + package
cd personaplex-mac && ./build.sh && open PersonaPlexMac.app
```

The `.app` bundle is required — SwiftUI needs it for microphone permission, and
the ad-hoc signature keeps the grant across rebuilds.

## Using it

**Wear headphones.** The model is full-duplex, so on speakers it hears its own
voice and interrupts itself. There is an echo-suppression toggle that mutes the
mic while the agent speaks, but that removes barge-in — the whole point of a
full-duplex model. Real AEC is not available on this machine (`VPIO` fails to
initialize with an output path); see `../PERSONAPLEX.md`.

- **Precision** — switch between the 8-bit and 4-bit builds live. They measure
  about the same per step; 4-bit is 3.7 GB smaller and loads faster.
- **Persona** — free text. This is what PersonaPlex is for; the voice picker sets
  timbre, the persona field sets who they are.
- **Mode** — full-duplex (default) or turn-based. Turn-based needs VAD weights;
  if they can't be fetched the app stays in full-duplex rather than failing.
- The HUD shows rolling **ms/step against the 80 ms frame budget**. Under 80 =
  real-time.

## Headless benchmark

Compares both precisions without a mic:

```bash
PersonaPlexMac.app/Contents/MacOS/PersonaPlexMac --bench ../hello.wav 450
```

Run it at two step counts and take the slope — a single number folds in the
fixed voice-prompt prefill and overstates ms/step badly at low step counts.

## Differences from the upstream demo

- No Qwen3-ASR (unused by full-duplex, and a second MLX model on another thread
  is the documented crash case)
- Runtime precision picker; weights loaded from the local HF cache, never downloaded
- **Voice prompts actually load.** `fromPretrained(cacheDir:)` covers the weights
  but not the voice presets, which resolve through a separate `modelId`-derived
  path and fail *silently* to "no voice prompt". `linkLibraryCache()` symlinks
  that path to the snapshot; without it the model sounds generic and says nothing
  about it.
- Live per-step latency HUD
- Free-text persona instead of a hardcoded token array
- Full-duplex is the default; turn-based degrades gracefully

## Known limitations

- No live transcript in full-duplex — `respondRealtime()` yields audio only
- English only; short exchanges work best
- No EOS token: full-duplex runs until stopped
