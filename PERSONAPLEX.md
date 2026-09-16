# PersonaPlex 7B on Apple Silicon — research + local setup

NVIDIA's PersonaPlex-7B-v1 is a **full-duplex speech-to-speech** model: audio in,
audio out, no ASR→LLM→TTS cascade. It listens and speaks at the same time, so
barge-in, overlap and backchannels are native behaviours rather than app-level
tricks. Released 2026-01-15 under the NVIDIA Open Model License (commercial use
permitted); code MIT/Apache-2.0.

This document records what was researched, what was installed on this machine,
and what the measurements actually say — including two places where the
published claims contradict each other.

## Architecture

It is Moshi (Kyutai), fine-tuned by NVIDIA — `base_model` in the config is
literally `kyutai/moshiko-pytorch-bf16`.

| Component | Shape | Job |
|---|---|---|
| Mimi codec | SEANet + 8-layer transformer, 16 codebooks, 12.5 Hz, 24 kHz | audio ↔ tokens |
| Temporal transformer | 32 layers, 4096 dim, 32 heads | the 7B; interleaved text + audio streams |
| Depformer | 6 layers, 1024 dim, 16 steps, weights-per-step | 16 audio codebooks per frame |

One frame = **80 ms** (12.5 Hz). Everything about latency reduces to a single
number: **can a step finish inside 80 ms?** Under that, the model is real-time
(RTF < 1); over it, you buffer and drift.

Persona is set two ways, both required for a convincing character:
- **voice prompt** — a `.safetensors` embedding (18 presets: NATF/NATM 0-3, VARF/VARM 0-4) carrying timbre and prosody
- **text prompt** — role/background/scenario as SentencePiece tokens

Custom personas survive the port: despite the class being named
`SentencePieceDecoder`, it has a real `encode(_:)` / `encodeSystemPrompt(_:)`,
and `respond(systemPrompt: String, …)` takes **free text**. So arbitrary personas
work on the Swift side, not just the baked-in presets — this was the biggest
feared gap and it isn't one.

The model also emits a text "inner monologue" alongside audio, which is what you
display as a live transcript. There is **no EOS token** — in turn-based use you
cap `maxSteps` (75 steps ≈ 6 s); in full-duplex it simply runs until stopped.

## The three artifacts, and why they are not interchangeable

This is the single most important practical finding, and it is not stated
plainly anywhere upstream:

| Repo | Layout | Loads in |
|---|---|---|
| `nvidia/personaplex-7b-v1` (17.1 GB) | original PyTorch/moshi checkpoint | **Python port only** |
| `aufklarer/PersonaPlex-7B-MLX-8bit` (9.8 GB) | pre-split `temporal`/`depformer`/`embeddings`/`mimi`.safetensors | **Swift only** |
| `aufklarer/PersonaPlex-7B-MLX-4bit` (5.8 GB) | same split layout | **Swift only** |

The Python port (`mu-hashmi/personaplex-mlx`) downloads NVIDIA's checkpoint and
quantizes **on the fly** (`-q 4` / `-q 8`, or omit for bf16). The Swift package
(`soniqo/speech-swift`) loads the **pre-quantized** split files and reads bits /
group_size from the repo's `config.json`.

So there is no single apples-to-apples grid. There are two comparisons:
- **Python:** bf16 vs `-q 8` vs `-q 4`, same input wav, same seed — deterministic
- **Swift:** 8-bit repo vs 4-bit repo — the numbers that the app will actually feel

Good news for the app: the Swift loader is **not** hardcoded to 4-bit. It parses
`config.json`'s `quantization` block (`bits`, `group_size`, `quantized_components`)
and falls back to BF16 when absent, so a model picker over both repos is a
matter of passing a different `modelId`.

### Contradiction #1 — is 4-bit fine, or bad?

- The **blog post** says 4-bit is lossless ("no measurable quality loss in ASR round-trip tests") at ~68 ms/step.
- The **4-bit model card**, same author, says 4-bit "degrades PersonaPlex response quality significantly" and that int8 is *both* better and ~30% **faster** (112 vs 158 ms/step).

The card offers a mechanism for "8-bit is faster": that the 4-bit build leaves
the temporal attention **input** projection at fp16 because of its packed
layout, so it pays for mixed-precision kernel switching. **That is not true of
these repos.** Dumping the safetensors headers for layer 0 of each:

```
4-bit   self_attn.in_proj_weight   U32 [12288,  512]  + scales/biases F16 [12288, 64]
8-bit   self_attn.in_proj_weight   U32 [12288, 1024]  + scales/biases F16 [12288, 64]
```

`in_proj` is quantized in **both** (U32 packed + scales + biases is exactly MLX's
quantized-layer signature; the fp16 case would be a bare `F16` weight with no
scales). The 512-vs-1024 U32 columns are just 4096 input values packed at 4 vs 8
bits, and both use `group_size: 64`. Every layer tensor follows the same pattern.

So the two builds are **structurally identical and differ only in `bits`**. If
8-bit really is faster, it is not for the published reason — a plausible
alternative is that MLX's int8 matmul kernels beat int4 at these shapes, with
the dequantization cost outweighing the memory-bandwidth saving. Either way this
has to be measured, not reasoned about.

### Contradiction #2 — is the depformer quantized?

The 4-bit card says depformer and Mimi were "left unquantized for quality." The
repo's own `config.json` says otherwise, in both builds:

```json
"quantization": { "bits": 4, "group_size": 64,
                  "quantized_components": ["temporal", "depformer"] }
```

and `depformer.safetensors` is **698 MB** at 4-bit / **1.3 GB** at 8-bit (bf16
would be ~2.4 GB). The config is what the loader obeys, so: temporal **and**
depformer are quantized; only Mimi (367 MB, identical in both) and the
embeddings (943 MB, identical in both) stay fp16. Trust the config, not the card.

## The "live server"

`NVIDIA/personaplex` is the reference server — it is **CUDA-only** (A100/H100,
Linux) and will not run here. The usable live server on this machine is the
Python port's web mode, which serves the same idea over a local web UI:

```
python -m personaplex_mlx.local_web -q 8 --voice NATF2      # http://localhost:8998
python -m personaplex_mlx.local        # terminal, realtime
python -m personaplex_mlx.offline --input-wav … --output-wav …   # deterministic
```

Both of its interactive clients ship **without echo cancellation** and tell you
to wear headphones.

## Echo cancellation — measured, not assumed

A full-duplex model on speakers hears its own voice and barges in on itself, so
AEC is the difference between a demo and something usable. The obvious answer on
macOS is Apple's Voice-Processing I/O (VPIO). It was tested directly on this
machine (M5 Max, macOS 26.4), each variant in a throwaway process because a
failed attempt poisons the audio HAL:

| Variant | Result |
|---|---|
| VPIO on input, **no output path connected** | **works** — 29 buffers in 3 s, engine healthy |
| VPIO on input, output path connected | `start()` fails, **-10875** at `PerformCommand(*outputNode, kAUInitialize)` |
| VPIO on input+output | same -10875 |
| Above, with input device pinned to built-in mic | same -10875 (pin itself fails, -10851) |

So VPIO is fine right up until the graph gains a render path — i.e. it fails in
exactly the full-duplex configuration we need. Root cause is visible in the
device enumeration: `AVAudioEngine`'s input node does not open the built-in mic,
it opens `CADefaultDeviceAggregate-85571-0`, and with VPIO on it enumerates as
**9 channels**. This machine has several virtual audio devices installed
(BlackHole 2ch, ZoomAudioDevice, a DAWPro test aggregate); the crowded HAL is
the most likely reason the VPIO unit cannot initialize its output side.

This reproduces the earlier debugging saga recorded in project memory, and adds
the part that was missing: it is the **output-node initialization** that fails,
not input capture. **Worth one experiment, and it needs you rather than me:** unload the virtual
audio drivers (BlackHole, ZoomAudioDevice, the DAWPro aggregate) and re-run
`scratchpad/vpio2.swift`. If VPIO then initializes with an output path, the
clean one-engine design becomes available and phase 2 gets much simpler.

Failing that, the honest options are:

1. **Headphones** — what every existing client does.
2. **Software AEC with our own reference signal.** We *generate* the agent audio,
   so we know the far-end signal exactly and don't need the OS to tell us. Vendor
   `libspeexdsp` (or WebRTC AEC3) as an SPM C target; align render-to-capture
   delay from `outputNode.presentationLatency + inputNode.presentationLatency`
   with a ~200 ms filter tail. This is the real differentiator over both
   upstream clients.
3. **Zero-injection gating** (what `PersonaPlexDemo` does: write silence into the
   mic ring buffer while the agent speaks). Cheap, but it destroys barge-in —
   which is the entire point of a full-duplex model. Not AEC; don't ship it as such.

## Neural Engine — a straight answer

The ask was "run it on the Neural Engine without limitations." That is not
available, and not for a reason a workaround fixes:

- **MLX is Metal/GPU-only.** It has no ANE backend. Both ports here are MLX.
- Reaching the ANE means **Core ML**, which wants static shapes and fp16. A 7B
  autoregressive decoder with a growing KV cache is the opposite of that — you'd
  need fixed-length cache buckets and per-bucket compiled models, and ANE has no
  int4/int8 path that would keep the weights in memory at this size.
- The ANE is also throughput-oriented with a small working set; a 7B model's
  weight streaming would dominate, and it would very likely be **slower** than
  the GPU here, not faster.

What *is* plausibly ANE-worthy: the **Mimi encoder/decoder** (small, fixed 80 ms
frames — a genuinely good Core ML candidate) and a VAD. Moving those off the GPU
frees GPU time for the transformer. That is a real optimization; "7B on the ANE"
is not. On the reference M2 Max the GPU path runs ~80-95 ms/step; an M5 Max is
expected to sit comfortably under the 80 ms budget (measured below), so the
GPU — not the ANE — is where this already works.

## Installed on this machine

Added to the `mlxmgr` catalog (`mlxmgr list`):

| Slug | What |
|---|---|
| `personaplex-bf16` | NVIDIA reference checkpoint (gated; HF token required) |
| `personaplex-mlx-8bit` | pre-quantized 8-bit, for Swift |
| `personaplex-mlx-4bit` | pre-quantized 4-bit, for Swift |
| `personaplex-mlx-py` | the Python/MLX port, cloned to `ext/personaplex-mlx` |

Environments:
- `.venv-personaplex` — **Python 3.12** (the port pins `>=3.10,<3.13`; the repo's
  main `.venv` is 3.14 and cannot install it)
- `ext/speech-swift` — the Swift package (Apache-2.0), built with `make build`

A/B harness: `scripts/personaplex_ab.sh` (offline wav→wav across bf16/8/4).

### Gotchas worth remembering

- `swift build` failed once with a **stale SwiftPM binary artifact** cache
  (`SpeechCore.xcframework.zip` "already exists in file system"). Fix: delete
  `~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_soniqo_*` and rebuild.
- The Swift side downloads into `~/Library/Caches/qwen3-speech/`, **not** the HF
  cache. `PersonaPlexModel.fromPretrained(modelId:cacheDir:offlineMode:)` accepts
  an explicit `cacheDir` — point it at the mlxmgr HF snapshot and pass
  `offlineMode: true` to avoid re-downloading through a network path that
  Netskope tends to block.
- **`cacheDir` only governs the weights — voice prompts ignore it.** This one is
  nasty because it fails silently. `fromPretrained(cacheDir:)` loads the four
  weight files and the tokenizer from the directory you pass, but voice prompts
  are loaded at four separate sites in `PersonaPlex.swift` (150, 639, 1028, 1346)
  through `modelCacheDirectory()`, which re-derives the path from `modelId` as
  `~/Library/Caches/qwen3-speech/models/<org>/<repo>`. All four treat a missing
  file as "no voice prompt" rather than an error — so the model loads, runs, and
  produces perfectly fluent speech in a *generic* voice, with nothing in the logs.
  The persona voice is simply absent. `linkLibraryCache()` in our view model
  symlinks that path to the HF snapshot, which fixes all four sites at once
  without patching the library. **Any earlier benchmark, ours included, was
  measured without a voice prompt.**
- **The process holds ~100 GB, and it is not the model.** Weights are 9.1 GB
  (8-bit) / 5.4 GB (4-bit). MLX keeps freed GPU buffers in a scratch pool rather
  than returning them, and mlx-swift's default ceiling for that pool is the Metal
  device's `recommendedMaxWorkingSetSize` — **107.5 GB on this 128 GB M5 Max**
  (measured). Sustained decoding allocates heavily per frame (32 temporal layers
  + 16 depformer steps), so the pool climbs toward that ceiling and forces
  everything else to swap long before MLX feels any pressure. It is reclaimable
  cache, not a leak, but the practical effect is a wedged machine. Every other
  model in speech-swift caps it (`Qwen3ASRMemory.cacheLimitForLarge`, plus
  `Memory.clearCache()` in Voxtral/Moss/F5TTS/Chatterbox/Nemotron);
  **PersonaPlex is the only one that sets no limit and calls no clearCache.**
  Our `boundMLXCache()` caps it at `min(8 GB, 25% RAM)`, and `releaseModel()`
  calls the library's own `unload()` + `clearCache()` — `model = nil` alone frees
  nothing, which is why switching precision used to stack both models and OOM.
- **MLX's compiler cache is not thread-safe.** Running a second model (ASR, VAD)
  on another thread alongside PersonaPlex crashes. One inference thread; energy
  VAD only.
- Audio is **24 kHz mono, 1920-sample frames**. Don't reuse voicechat-mac's
  16 kHz downsampling path.

## Measurements

All on this machine: M5 Max, 128 GB, macOS 26.4.

### Swift path (`speech-swift`) — the numbers the app feels

`PersonaPlexMac --bench hello.wav <steps>`, turn-based `respond()`, after warmup:

| steps | 8-bit ms/step | 4-bit ms/step |
|---|---|---|
| 150 | 101.3 | 58.1 |
| 450 (run 1) | 81.4 | 68.0 |
| 450 (run 2) | 66.4 | 63.9 |

Single-shot ms/step folds in a fixed cost (voice-prompt prefill + user audio),
which is why 150 steps looks so much worse. Taking the slope between 150 and 450
steps removes it: **~71 ms/step for 8-bit, ~73 ms/step for 4-bit** — i.e. the
marginal cost of a frame is *the same* within noise, and run-to-run variance
(66-81 ms for 8-bit) is larger than the gap between the two builds.

So the honest reading: **both builds sit at roughly 60-80 ms/step, at or just
inside the 80 ms real-time budget.** 4-bit's advantage in any single short run is
lower fixed overhead (smaller load, cheaper prefill), not faster steps.

Those figures are `respond()` — turn-based. Full-duplex (`respondRealtime()`)
adds a Mimi *encode* of the incoming frame on every step, which upstream measures
at ~10-15 ms, so the live number should be expected to land **near or just over
the 80 ms line**, with the 3-frame prebuffer absorbing jitter rather than a
comfortable margin doing it. The in-app HUD is the arbiter — trust it over this
table for the full-duplex case.

Load from warm page cache is 1-2 s for both; warmup 0.1 s after the first run.

### Python path (`personaplex-mlx`) — quality across precisions

Wall-clock here is dominated by loading weights (17 / 9 / 5.4 GB), so
`scripts/personaplex_steptime.sh` runs each precision at two input lengths and
takes the slope, cancelling load:

| precision | ms/step | load overhead |
|---|---|---|
| bf16 | 262 | 4.6 s |
| int8 | 167 | 11.0 s |
| int4 | 126 | 9.1 s |

These are **relative, not absolute** — this port pins `mlx <0.27` and does not
use the compiled/fused graph the Swift package does, which is why every figure
is roughly 2x the Swift equivalent and all three miss the 80 ms budget. Use them
to rank precisions, not to judge feasibility.

### Verdict on the published claims

**"int8 is ~30% faster than int4 (112 vs 158 ms/step)" does not reproduce — in
either runtime.** Python: int4 is *faster* (126 vs 167). Swift: the two are equal
within noise once fixed cost is removed. Nothing measured here supports paying
3.7 GB extra for 8-bit on speed grounds.

On quality, one sample each (same seed, same voice, same input) — all three
produced fluent, well-formed English:

- bf16 — "I think it's going to be a tight game, you know, both teams are playing hard, so we'll see what happens, yeah?"
- int8 — "Yeah, that was the day we finally got the win, right?"
- int4 — "Hey, let me know if you have any... Yeah, the winning run was a home run, it cleared the fence, the crowd went crazy, you could hear it all over the park."

Different text from the same seed is expected — quantization perturbs logits and
the samples diverge — so this **cannot rank the precisions**; N=1 proves nothing.
What it does show is no *obvious* degradation at 4-bit: the card's "degrades
response quality significantly" is not visible in this sample. The wavs are in
`scratch/personaplex-ab/` — listening is the real test.

(Note the replies are about baseball and the input is a short greeting. That is
the documented "tangential answers" behaviour of the 7B with no persona set, not
a bug — which is exactly why the app exposes a free-text persona field.)

## The app: `personaplex-mac`

A fork of `speech-swift`'s `Examples/PersonaPlexDemo` (Apache-2.0), because
starting from a working full-duplex loop beats rewriting `respondRealtime()` +
ring buffer + streaming player from scratch. What changed:

- **No Qwen3-ASR.** Full-duplex never used it; it is a second MLX model on
  another thread, which is the documented crash case, and another blocked download.
- **Precision picker** over both aufklarer builds, switchable at runtime — the
  library reads `bits` from `config.json`, so it is just a different `modelId`.
- **Weights load from the local HF cache** (`mlxmgr` snapshots) with
  `offlineMode: true`, so nothing is fetched at launch.
- **Latency HUD** — rolling mean/peak ms/step against the 80 ms budget, live
  during full-duplex. This is the number that decides real-time, and it is
  measured on `respondRealtime()`, which is more expensive per step than the
  benchmark's `respond()` because it also Mimi-*encodes* a mic frame each step.
- **Free-text persona field** instead of the demo's hardcoded token array.
  `SentencePieceDecoder.encodeSystemPrompt` wraps the text in `<system>` tags
  itself, so arbitrary personas work correctly.
- **Full-duplex is the default mode**; turn-based degrades gracefully if the VAD
  weights can't be fetched rather than failing the whole load.

Build and run:

```
cd personaplex-mac && ./build.sh && open PersonaPlexMac.app
```

**Wear headphones.** Echo suppression (mic gating) is available for speakers but
it kills barge-in; see the AEC section.

### Known limitations

- **No live transcript in full-duplex.** `respondRealtime()` yields `[Float]`
  only — the text stream is not surfaced by the library. Turn-based does show
  the monologue. Exposing it in full-duplex means patching `speech-swift`.
- **English only**, and short exchanges work best (7B, documented upstream).
- **No EOS**: full-duplex runs until stopped; turn-based is capped by `maxSteps`.

## Sources

- https://huggingface.co/nvidia/personaplex-7b-v1
- https://github.com/NVIDIA/personaplex
- https://github.com/mu-hashmi/personaplex-mlx
- https://github.com/soniqo/speech-swift
- https://huggingface.co/aufklarer/PersonaPlex-7B-MLX-4bit
- https://huggingface.co/aufklarer/PersonaPlex-7B-MLX-8bit
- https://blog.ivan.digital/nvidia-personaplex-7b-on-apple-silicon-full-duplex-speech-to-speech-in-native-swift-with-mlx-0aa5276f2e23
