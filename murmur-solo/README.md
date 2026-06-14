# Murmur Solo — fully on-device voice typing

The self-contained sibling of [Murmur](../murmur-mac). Same minimalist UX — hold
a key, speak, release, and your words are typed into the focused app — but
**transcription runs entirely on-device** via `whisper.cpp` (Metal), with the
Whisper `large-v3-turbo` model bundled into the app. No Python, no omlx server,
no network.

It exists as a *separate* app so you can run it alongside Murmur and compare
quality and latency: Murmur uses the MLX/omlx server; Solo uses CoreML-free
whisper.cpp on Metal. Same model weights → same transcription quality; the
runtimes differ. Solo's default trigger is **Right ⌘** (Murmur uses Right ⌥),
so both can run at once without fighting over a key.

## Architecture

```
  hold Right ⌘   ──►  AVAudioEngine (16 kHz mono Float32)  + live RMS meter
   (release)     ──►  whisper.cpp  whisper_full()  (Metal, on-device)
                 ──►  clipboard paste (⌘V) into the focused app, then restore
```

No server, no cleanup LLM — just capture → whisper.cpp → paste.

## Build

Two steps: build the whisper.cpp static library once, then build the app.

```bash
./build-whisper.sh     # compiles whisper.cpp (Metal) -> Frameworks/whisper/lib + headers
                       # needs cmake (brew install cmake); CLT only, no full Xcode
./build.sh             # builds MurmurSolo.app, bundles the model, ad-hoc signs
open MurmurSolo.app
```

### The model (one-time, ~1.6 GB)
The model is **not** committed (too large). Put it at `Models/ggml-large-v3-turbo.bin`
before `./build.sh`:

```bash
mkdir -p Models
# download via browser (the CLI path is blocked on some networks):
#   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true
mv ~/Downloads/ggml-large-v3-turbo.bin Models/
```

`build.sh` copies it into `MurmurSolo.app/Contents/Resources/`. Smaller
quantized variants (`ggml-large-v3-turbo-q8_0.bin`, `-q5_0.bin`) also work —
rename to `ggml-large-v3-turbo.bin` or adjust the model name.

## Permissions (same three as Murmur)
On first launch grant, in System Settings › Privacy & Security:
- **Microphone** — to hear you
- **Input Monitoring** — so the hold-key fires
- **Accessibility** — to paste into the focused app

The menu-bar menu shows live ✓/⚠ for each, plus model-load status.

> Ad-hoc signed: every rebuild changes the code hash and macOS silently
> invalidates Input Monitoring / Accessibility grants. If the hotkey stops
> working after a rebuild, toggle those off/on again (or
> `tccutil reset Accessibility com.local.murmursolo` /
> `tccutil reset ListenEvent com.local.murmursolo`) and relaunch.

## Distribute to another Apple Silicon Mac
`./package-dmg.sh` builds the app (model bundled) and produces
`MurmurSolo.dmg` — drag to Applications. It's ad-hoc signed, **not notarized**,
so on the target Mac the first launch needs right-click → Open (or
`xattr -dr com.apple.quarantine /Applications/MurmurSolo.app`). Apple Silicon,
macOS 13+ only.

## Layout

```
Package.swift              SPM: CWhisper (C module) + MurmurSolo (executable)
build-whisper.sh           build + stage whisper.cpp static lib & headers
build.sh                   build app, bundle model, ad-hoc sign
package-dmg.sh             produce a distributable .dmg
Frameworks/whisper/lib/    libwhisper_all.a (built; gitignored)
Models/                    ggml-large-v3-turbo.bin (downloaded; gitignored)
Sources/CWhisper/          C module map + vendored whisper.cpp headers
Sources/MurmurSolo/
  App.swift                @main, menu bar, model-status, settings
  WhisperTranscriber.swift on-device whisper.cpp wrapper (actor)
  AudioRecorder.swift      capture -> 16 kHz mono Float32 + RMS meter
  DictationController.swift state machine + gestures
  HotkeyMonitor.swift      CGEventTap on the activation modifier
  TextInjector.swift       clipboard-paste insertion
  HUDPanel.swift / HUDView.swift   flowing always-on overlay
  Settings.swift / SettingsView.swift
  DebugLog.swift
```
