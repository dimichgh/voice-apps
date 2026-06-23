# Murmur WK — on-device voice typing via WhisperKit (CoreML / ANE)

The third sibling in the comparison set. Same minimalist UX as
[Murmur](../murmur-mac) and [Murmur Solo](../murmur-solo) — hold a key, speak,
release, text is typed into the focused app — but transcription runs through
**WhisperKit** (Apple CoreML, using the **Neural Engine**) with the
`large-v3-turbo` CoreML model bundled. Fully offline.

| App | Engine | Runtime | Default key |
|---|---|---|---|
| Murmur | omlx server | MLX (Metal GPU) | Right ⌥ |
| Murmur Solo | whisper.cpp | Metal GPU | Right ⌘ |
| **Murmur WK** | WhisperKit | **CoreML / ANE** | **fn** |

Same `large-v3-turbo` weights across all three → same transcription quality;
they differ in runtime/accelerator, which is what you're comparing. Distinct
default triggers mean all three can run at once.

## Architecture

```
  hold fn        ──►  AVAudioEngine (16 kHz mono Float32) + live RMS meter
   (release)     ──►  WhisperKit.transcribe(audioArray:)  (CoreML, ANE+GPU)
                 ──►  clipboard paste (⌘V) into the focused app, then restore
```

WhisperKit (the `argmax-oss-swift` package) is a normal SwiftPM dependency, so
there's no separate native-lib build step — just add the model and build.

## Install (one command)

```bash
./install.sh             # fetch CoreML model + tokenizer (if missing), then build
./install.sh --assemble  # rebuild the model folder from browser-downloaded blocked
                         #   files in ~/Downloads/whisperkit-dl/, then build
```

Idempotent: it pulls the CoreML model + tokenizer via
`huggingface_hub.snapshot_download`. If that fails (e.g. a network that blocks
Hugging Face LFS, where the big `weight.bin` blobs 403), run
`BROWSER=1 ./install.sh` to open the manifest (`whisperkit-download.html` /
`MANUAL_DOWNLOAD.txt`), browser-download the files into `~/Downloads/whisperkit-dl/`,
then `./install.sh --assemble` reconstructs the folder and builds. Prefer this
over the manual steps below.

## Build

```bash
# 1) Get the model + tokenizer into Models/ (see below)
./build.sh                 # resolves WhisperKit, builds, bundles model+tokenizer, ad-hoc signs
open MurmurWK.app
```

### The model + tokenizer (one-time, ~1.5 GB, not committed)
WhisperKit needs the CoreML model folder **and** a tokenizer, both placed under
`Models/`:

```
murmur-wk/Models/
  openai_whisper-large-v3-v20240930_turbo/   # the CoreML model (24 files)
  tokenizer/                                 # whisper-large-v3 tokenizer JSON
```

- **Tokenizer** (small, regular files) — fetchable normally:
  `huggingface-cli download openai/whisper-large-v3 --include "*.json" "merges.txt" --local-dir Models/tokenizer`
  (or the Python `snapshot_download`).
- **CoreML model** — on networks that block Hugging Face LFS, download the 14
  blocked files via browser using the generated manifest
  (`MANUAL_DOWNLOAD.txt` / `whisperkit-download.html`) and reassemble. The repo
  is `argmaxinc/whisperkit-coreml`, variant `openai_whisper-large-v3-v20240930_turbo`.

> **First launch is slow (~1–2 min):** CoreML "specializes" the model to your
> chip on first load and caches the result; later launches are fast. The
> menu shows "Loading model…" until it's ready.

## Permissions (same three as the others)
Microphone, Input Monitoring (hotkey), Accessibility (typing) — granted in
System Settings › Privacy & Security; the menu shows live ✓/⚠ + model status.

> Ad-hoc signed: rebuilds invalidate Input Monitoring / Accessibility grants.
> If the hotkey stops firing after a rebuild, re-toggle them (or
> `tccutil reset ListenEvent com.local.murmurwk` /
> `tccutil reset Accessibility com.local.murmurwk`) and relaunch.

## Distribute to another Apple Silicon Mac
`./package-dmg.sh` (or `./install.sh --dmg`) builds the app with the CoreML model
bundled and produces `MurmurWK.dmg` — drag to Applications. It's ad-hoc signed,
**not notarized**, so on the target Mac the first launch needs right-click → Open
(or `xattr -dr com.apple.quarantine /Applications/MurmurWK.app`). Then expect the
one-time ~1–2 min CoreML specialization on that Mac before it transcribes. Apple
Silicon, macOS 13+ only.

## Layout

```
Package.swift              SPM: depends on WhisperKit (argmax-oss-swift)
build.sh                   build app, bundle model+tokenizer, ad-hoc sign
Models/                    CoreML model + tokenizer (downloaded; gitignored)
Sources/MurmurWK/
  App.swift                @main, menu bar, model-status, settings
  WhisperKitTranscriber.swift   WhisperKit wrapper (actor, offline config)
  AudioRecorder.swift      capture -> 16 kHz mono Float32 + RMS meter
  DictationController.swift state machine + gestures
  HotkeyMonitor.swift / TextInjector.swift / HUDPanel.swift / HUDView.swift
  Settings.swift / SettingsView.swift / DebugLog.swift
```
