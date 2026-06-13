# Murmur — voice typing for macOS

A minimalist dictation app: hold a key, speak, release — your words are typed
into whatever app currently has focus. Like Wispr Flow / superwhisper, but
fully local, talking to the same **omlx** server the `voicechat-mac` app uses.

Murmur is a **separate app** from VoiceChat. It runs as a menu-bar agent (no
Dock icon) and floats a tiny non-activating HUD so it never steals focus from
the field you're dictating into.

## How it works

```
  hold Right ⌥   ──►  AVAudioEngine (16 kHz mono PCM16 WAV) + live RMS meter
   (release)     ──►  POST /v1/audio/transcriptions      (Whisper via omlx)
  [optional]     ──►  POST /v1/chat/completions          (LLM cleanup pass)
                 ──►  clipboard paste (⌘V) into the focused app, then restore
```

The HUD shows a live waveform while you speak (so you know it's hearing you),
then a spinner while transcribing, then a checkmark as it inserts.

### Gestures
- **Hold to talk** — hold the activation key, speak, release. Transcribes and
  inserts on release.
- **Double-tap to lock** — two quick taps start a hands-free session that keeps
  recording until you tap once more. Talk without holding the key.

The activation key (Right ⌥ Option by default; Right ⌘ or fn also available) is
a bare modifier, so it never emits text of its own into your document.

## Why clipboard paste for insertion

Synthesizing the text as unicode keystrokes is unreliable past ~20 characters
and breaks in Electron/terminal/secure fields. So Murmur does what production
dictation apps do: save your pasteboard, put the transcript on it, synthesize
⌘V, then restore the pasteboard a beat later (the delay matters — paste is
async, and restoring too soon makes the target read the *old* clipboard).

## Build & run

```bash
./build.sh            # builds Murmur.app, ad-hoc signed
open Murmur.app       # appears in the menu bar (mic icon)
```

### Permissions (three separate grants, all needed)
On first run, grant these in **System Settings › Privacy & Security**:
- **Microphone** — to hear you (Murmur prompts on launch).
- **Accessibility** — to post the ⌘V paste keystroke into other apps.
- **Input Monitoring** — to observe the global hold-to-talk key.

The menu-bar menu shows live ✓/⚠ status for Microphone and Accessibility and
links straight to the relevant settings pane. Because Murmur is ad-hoc signed,
TCC remembers the grants across launches.

> Note: a stable bundle/signature is what TCC keys grants off of. If you rebuild
> and the grants seem forgotten, re-toggle them in System Settings.

## Prerequisites

The omlx OpenAI-compatible server must be running (same one `voicechat-mac`
uses), with a Whisper STT model available:

```bash
../.venv/bin/omlx serve --port 8000
```

Defaults (changeable in **Settings…**):
- Server: `http://127.0.0.1:8000`
- Speech model: `mlx-community--whisper-large-v3-turbo-asr-fp16`
- Cleanup model: `mlx-community--Qwen3-Omni-30B-A3B-Instruct-8bit` (off by default)

## Settings

Menu bar → **Settings…**:
- **Activation key** — Right ⌥ / Right ⌘ / fn.
- **Clean up with local model** — LLM pass to fix punctuation and drop filler
  words. Off by default (adds a round-trip; latency is the whole game). The
  cleanup prompt is a strict filter — it will *not* answer dictated questions.
- **Sound feedback** — a subtle tick on start / pop on stop.
- **Server / model** fields.

## Layout

```
Package.swift              SwiftPM executable (macOS 13+)
Resources/Info.plist       LSUIElement agent app + mic usage string
build.sh                   build + bundle + ad-hoc sign
Sources/Murmur/
  App.swift                @main, menu-bar status item, settings window
  DictationController.swift state machine + gesture interpretation
  HotkeyMonitor.swift       CGEventTap on the activation modifier
  AudioRecorder.swift       AVAudioEngine capture → WAV + live RMS level
  TranscriptionClient.swift omlx transcribe + optional cleanup
  TextInjector.swift        clipboard-paste insertion into the focused app
  HUDPanel.swift            non-activating floating panel host
  HUDView.swift             minimalist capsule + animated waveform
  SettingsView.swift        settings form
  Settings.swift            UserDefaults-backed prefs
  DebugLog.swift            stderr trace (run the binary in a terminal to watch)
```

## What's verified vs. what needs a live machine

Builds, bundles, ad-hoc signs, and launches as a menu-bar agent without
crashing (the CGEventTap installs and starts watching the trigger key). The
full **hotkey → record → transcribe → paste** loop can only be exercised on a
machine with the three permissions granted, a running omlx server, and a real
focused target app — that part has not been run here. Run the binary from a
terminal to watch the `[murmur …]` trace as you test:

```bash
./Murmur.app/Contents/MacOS/Murmur
```
