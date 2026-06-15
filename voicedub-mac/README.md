# voicedub-mac

Native SwiftUI macOS app for **voice cloning/design** and **video dubbing**,
built on the local omlx server (Apple Silicon). A sibling to `voicechat-mac` and
the `murmur-*` apps — copies their shared building blocks (`OmlxClient`,
`AudioCapture`, `AudioPlayer`, `VoiceCatalog`) and adds a dubbing pipeline.

## What it does (v1)

**Voices tab**
1. **Record** a voice sample → cloned with OmniVoice for TTS.
2. **Design** a voice from a text description ("gravelly older detective") →
   OmniVoice's instruct channel generates it; the take is frozen as a reusable
   cloning reference.
3. **Text → Speech** playground: type text, hear it in the selected voice.

**Dub Video tab**
4. Open a video → extract audio (ffmpeg) → transcribe with timed segments
   (Whisper via omlx) → optionally translate each segment (Qwen3-Omni) →
   regenerate dialogue in the selected voice → time-stretch each clip to fit its
   source span (keeps A/V in sync) → assemble one audio track.
5. **Play the redubbed video** in place via an `AVMutableComposition` (original
   video track + new audio) — no export needed. Toggle Dubbed/Original. Optional
   **Export…** writes a `.mov` with the video passed through losslessly.

## Pipeline

```
 video ─ffmpeg─► 16kHz mono WAV
       ──► POST /v1/audio/transcriptions (verbose_json) ─► timed segments
       ──► POST /v1/chat/completions      (Qwen3-Omni)   ─► per-segment translation [optional]
       ──► POST /v1/audio/speech          (OmniVoice)    ─► per-segment TTS in chosen voice
       ─ffmpeg atempo─► stretch each clip to its source duration
       ─ffmpeg amix──► one timed audio track
       ──► AVMutableComposition (orig video + new audio) ─► AVPlayer / passthrough export
```

## Why this toolchain

- **omlx** drives all three model ops: Whisper-large-v3-turbo (ASR with
  segments), Qwen3-Omni-30B (translation), OmniVoice-0.6B (cloning/design TTS).
- **ffmpeg** for the steps AVFoundation doesn't do cleanly: decoding a video's
  audio for ASR, time-stretching a clip to an exact duration, and pasting timed
  segments onto a silent canvas.
- **AVFoundation** for playback and export. `AVPlayer` plays an
  `AVMutableComposition` directly, so redubbed playback needs **no re-encode**;
  export uses `AVAssetExportPresetPassthrough` (video untouched).

## Prerequisites

1. **omlx server running** with the models discoverable in the HF cache:
   ```bash
   ../.venv/bin/omlx serve --port 8000
   ```
   Required models (already in this repo's catalog — see `../mlxmgr.py`):
   `OmniVoice-bf16`, `Qwen3-Omni-30B-A3B-Instruct-8bit`,
   `whisper-large-v3-turbo-asr-fp16`.
2. **ffmpeg / ffprobe** on the system (Homebrew/MacPorts/`/usr/bin`):
   `brew install ffmpeg`.
3. **Swift 5.9+** and Xcode CLT.
4. *(Optional)* **Demucs venv** for "Keep background music & sound effects"
   (voice/background separation). Without it that checkbox is disabled; the rest
   of the app works. Set it up once:
   ```bash
   VENV="$HOME/Library/Application Support/VoiceDub/demucs-venv"
   python3 -m venv "$VENV"
   "$VENV/bin/python" -m pip install demucs torchcodec
   ```
   `torchcodec` is required for Demucs to *write* its stems on recent torchaudio.
   Model weights download from Meta's CDN on first separation. The app finds the
   venv at that fixed path and runs `python -m demucs` (MPS, falling back to CPU).

## Build & run

```bash
./build.sh
open VoiceDub.app
```

Mic permission is only requested when you record a voice. Recorded/designed
voices persist under `~/Library/Application Support/VoiceDub/voices`.

## Configuration

Edit `OmlxConfig` in `Sources/VoiceDub/OmlxClient.swift` for the server URL and
model ids. Target languages for translation live in `AppModel.languages`.

## Known limitations

- **Time-stretch to fit** keeps A/V in sync, but a translation much longer than
  its source span needs heavy speed-up. We cap the speed-up at 1.6× (beyond that
  speech is unintelligible); past the cap the clip runs natural-ish but overflows
  into the gap after it, so a long line can briefly run past its on-screen
  moment. Shorter translations keep natural pace and pad with silence.
- **Sync is anchored at segment starts**, not word-level — fine for dialogue,
  looser for fast cross-talk.
- Export is `.mov` (lossless video passthrough + PCM audio). Not `.mp4`.
- **Background separation** (Demucs) assumes a single dominant speaker (no
  diarization) and leaves faint vocal residue under the music. The dub voice is
  mixed over the background with a peak limiter (no ducking yet). To preserve
  full dynamics, the original audio is used as-is in non-speech gaps and the
  vocal-removed stem only under speech — so SFX/music Demucs bleeds out of the
  stem (e.g. a roar) survive at full strength wherever they don't overlap a line.

## Not in v1 (planned)

- **Segment editor** (feature 7): edit/re-translate individual segments before
  regenerating, with per-segment re-voice.
- **Live on-the-fly dub** (feature 6): buffered, early-start playback with a
  fixed delay. Feasibility depends on per-chunk pipeline time staying under the
  chunk duration — benchmark before building.
- **AAC export to `.mp4`** (current export is `.mov` with PCM audio).
```
