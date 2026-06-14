# Murmur — three voice-typing apps, three engines

Murmur is a minimalist macOS voice-typing utility (à la Wispr Flow): hold a key,
speak, release, and the transcription is typed into whatever app is focused.

There are **three sibling apps** in this repo. They are intentionally near-identical
in UX and code so they can run side by side and be compared **A/B/C**. What differs
between them is the **speech-to-text engine** underneath — and the properties that
follow from that choice (offline vs. server, compute backend, model format,
first-launch cost, distributability).

| Property | **Murmur** (`murmur-mac`) | **Murmur Solo** (`murmur-solo`) | **Murmur WK** (`murmur-wk`) |
|---|---|---|---|
| STT engine | omlx server (MLX) | whisper.cpp | WhisperKit |
| Compute backend | Apple MLX, via a local HTTP server | GGML + **Metal** (GPU) | CoreML + **Apple Neural Engine** |
| Where it runs | separate `omlx` process (`127.0.0.1:8000`) | in-process (static lib) | in-process (CoreML) |
| Model | served by omlx | `ggml-large-v3-turbo.bin` (~1.6 GB) | `large-v3-v20240930_turbo` CoreML (~1.5 GB) + tokenizer |
| Self-contained? | **No** — needs the server running | **Yes** — bundled, fully offline | **Yes** — bundled, fully offline |
| Network | local HTTP to omlx | none | none |
| Optional LLM cleanup | **Yes** (chat-completions pass) | no | no |
| First-launch cost | server startup | model mmap (~1–2 s) | **one-time ~90 s** ANE specialization, then cached |
| Default hotkey | Right ⌥ Option | Right ⌘ Command | `fn` (Globe) |
| Bundle ID | `com.local.murmur` | `com.local.murmursolo` | `com.local.murmurwk` |
| Audio path | WAV (16-bit PCM) | Float32 samples | Float32 samples |

The distinct default hotkeys and bundle IDs are deliberate: **all three can be
installed and run at once**, so you can dictate the same sentence into each and
compare speed and accuracy directly.

## In what sense they differ

- **Compute target.** This is the real axis of comparison. Solo drives the
  **GPU** (Metal); WK drives the **Neural Engine** (CoreML/ANE); Murmur defers to
  an external **MLX** server. Same model family (large-v3-turbo), three different
  runtimes — so you're measuring the runtime, not the model.
- **Architecture.** Solo and WK do everything **in-process and offline** — the
  model is bundled in the `.app`. Murmur is a thin **client** that POSTs audio to a
  local OpenAI-compatible omlx server; it's the most flexible (model swaps,
  cleanup LLM) but it is **not standalone** — the server must be running.
- **Latency profile.** Solo loads fast and is warm immediately. WK pays a
  **one-time ~90 s** CoreML specialization on the *first* launch on a given Mac
  (cached thereafter; the HUD shows "Loading model…" while it warms). Murmur's
  latency depends on the server and the network round-trip (localhost).
- **Capabilities.** Only Murmur has the optional **cleanup pass** (a second LLM
  call that removes filler/voice artifacts). Solo and WK ship transcription only.
- **Distributability.** Solo and WK are the easy ones to hand to another Mac —
  one self-signed `.app` with the model inside, no dependencies. Murmur additionally
  requires deploying and running the omlx server.

## What they all share

Everything *except* the engine is the same code, copied across the three:

- The floating **glass HUD** (flowing waveform, draggable, near-transparent) and
  its right-click menu.
- **Gestures**: hold-to-talk, and double-tap to lock a hands-free session.
- **Text injection** via clipboard paste (save → set → ⌘V → restore).
- **Permissions**: Microphone, Input Monitoring, Accessibility — with the
  one-at-a-time setup flow and the "↻ restart to apply" signal (Input Monitoring
  and Accessibility, and the activation key, bind at launch).
- **Anti-hallucination**: an energy gate that skips (near-)silence so the model
  can't invent words on an empty clip.
- **Stable self-signed signing** (`Murmur Dev Signing`) so TCC permission grants
  survive rebuilds.

## Which to use

- **Want a single app to give someone, fully offline?** → **Solo** (Metal) or
  **WK** (ANE). Try both and keep whichever is faster/cleaner on the target Mac.
- **Want model flexibility or the cleanup LLM, and don't mind running a server?**
  → **Murmur** (omlx/MLX).
