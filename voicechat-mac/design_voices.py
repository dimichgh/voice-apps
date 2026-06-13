#!/usr/bin/env python3
"""design_voices.py — pre-generate OmniVoice character voices.

For each (id, label, description) in DESIGNED below, this:
  1. Sends the description to omlx /v1/audio/speech with model=OmniVoice and
     input=REF_SENTENCE. omlx routes the `voice` field to OmniVoice's
     `instruct` arg, so the description shapes the speaker.
  2. Saves the returned WAV under voices/<id>.wav.
  3. Appends a manifest entry that voicechat-mac loads as ref_audio + ref_text
     for deterministic cloning on every subsequent turn.

Kokoro presets are included in the same manifest so the Swift voice picker
shows everything in one dropdown.

Usage:
  ./design_voices.py                                # default omlx on :8000
  ./design_voices.py --base-url http://127.0.0.1:8000
  ./design_voices.py --ref-sentence "Custom reference sentence."
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VOICES_DIR = ROOT / "voices"
MANIFEST = VOICES_DIR / "voices.json"

OMNI_MODEL = "mlx-community--OmniVoice-bf16"
KOKORO_MODEL = "prince-canuma--Kokoro-82M"

REF_SENTENCE = (
    "Hello, this is a sample of my voice. "
    "I'm here to help you with whatever you need."
)

# (id, label, instruct-description) — feel free to add / replace.
DESIGNED: list[tuple[str, str, str]] = [
    ("warm-narrator",       "Warm Narrator",       "warm, calm, mature narrator voice with a measured pace"),
    ("bright-assistant",    "Bright Assistant",    "bright, energetic young woman, friendly and quick"),
    ("authoritative-news",  "Authoritative News",  "deep, authoritative male newsreader, clear and steady"),
    ("quirky-tech",         "Quirky Tech",         "quirky, cheerful AI tech assistant, mildly nerdy and curious"),
    ("gravelly-detective",  "Gravelly Detective",  "gravelly older man, world-weary detective tone"),
    ("contemplative-sage",  "Contemplative Sage",  "soft, contemplative philosopher, slow and thoughtful"),
    ("crisp-professor",     "Crisp Professor",     "crisp British professor, articulate and precise"),
    ("southern-friend",     "Southern Friend",     "friendly southern US woman, warm and approachable"),
]

# Kokoro voices the picker exposes alongside the designed ones.
KOKORO_PRESETS: list[tuple[str, str]] = [
    ("af_heart",   "Kokoro Heart (US ♀)"),
    ("af_bella",   "Kokoro Bella (US ♀)"),
    ("af_sky",     "Kokoro Sky (US ♀)"),
    ("am_adam",    "Kokoro Adam (US ♂)"),
    ("am_michael", "Kokoro Michael (US ♂)"),
    ("bf_emma",    "Kokoro Emma (UK ♀)"),
    ("bm_george",  "Kokoro George (UK ♂)"),
]


def post_speech(base_url: str, payload: dict) -> bytes:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/audio/speech",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", default="http://127.0.0.1:8000")
    ap.add_argument("--ref-sentence", default=REF_SENTENCE)
    ap.add_argument("--only", help="Comma-separated voice ids to (re)generate; default = all")
    args = ap.parse_args()

    VOICES_DIR.mkdir(parents=True, exist_ok=True)
    targets = set(args.only.split(",")) if args.only else None
    entries: list[dict] = []

    # Kokoro presets — no on-disk audio, just config.
    for vid, label in KOKORO_PRESETS:
        entries.append({
            "id": vid,
            "label": label,
            "kind": "kokoro",
            "model": KOKORO_MODEL,
            "voice": vid,
        })

    # OmniVoice designed voices — one HTTP round-trip each.
    for vid, label, description in DESIGNED:
        wav_path = VOICES_DIR / f"{vid}.wav"
        regen = targets is None or vid in targets
        if regen:
            print(f"==> designing  {vid:20s}  {description}")
            try:
                wav = post_speech(args.base_url, {
                    "model": OMNI_MODEL,
                    "input": args.ref_sentence,
                    "voice": description,    # omlx routes to OmniVoice's `instruct`
                    "response_format": "wav",
                    "stream": False,
                })
                wav_path.write_bytes(wav)
                print(f"    wrote {wav_path.relative_to(ROOT)} ({len(wav):,} bytes)")
            except urllib.error.HTTPError as e:
                body = e.read()[:300].decode("utf-8", errors="replace")
                print(f"    HTTP {e.code}: {body}", file=sys.stderr)
                continue
            except Exception as e:
                print(f"    FAIL: {type(e).__name__}: {e}", file=sys.stderr)
                continue
        elif not wav_path.exists():
            print(f"==> skipping   {vid:20s}  (no existing WAV, --only filter active)")
            continue
        else:
            print(f"==> keeping    {vid:20s}  {wav_path.relative_to(ROOT)}")

        entries.append({
            "id": vid,
            "label": label,
            "kind": "omni_cloned",
            "model": OMNI_MODEL,
            "description": description,
            "ref_audio_path": str(wav_path.relative_to(ROOT)),
            "ref_text": args.ref_sentence,
        })

    MANIFEST.write_text(json.dumps({"voices": entries}, indent=2) + "\n")
    print(f"\n==> wrote {MANIFEST.relative_to(ROOT)} with {len(entries)} voices")
    print("==> rebuild VoiceChat.app (./build.sh) to bundle the new voices.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
