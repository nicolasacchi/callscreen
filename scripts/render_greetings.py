#!/usr/bin/env python3
"""Render the 10 greeting variants × N voices into storage/greetings/<slug>/<voice>.wav.

Uses Kokoro TTS directly (the same engine the meditation project at
upstream TTS project uses). Installation:

    pip install 'kokoro>=0.9.4' soundfile torch

Or, if you already have meditation's venv with the [kokoro] extra:

    cd ~/project/vibe/meditation && pip install -e '.[kokoro]'

Then run from the callscreen project root:

    python3 scripts/render_greetings.py
    python3 scripts/render_greetings.py --voices if_sara
    python3 scripts/render_greetings.py --variants informal_tu,direct --force

Output is 24 kHz mono WAV. Telnyx's <Play> verb accepts WAV directly.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable, NamedTuple

CALLSCREEN_ROOT = Path(__file__).resolve().parent.parent
CATALOG_FILE = CALLSCREEN_ROOT / "app" / "models" / "greeting_catalog.rb"
OUTPUT_ROOT = CALLSCREEN_ROOT / "storage" / "greetings"
SAMPLE_RATE = 24000

DEFAULT_VOICES = ["if_sara", "im_nicola"]
# Map tone slug → Kokoro speed multiplier. Keep in sync with
# GreetingCatalog::TONES on the Ruby side.
DEFAULT_TONES = {
    "natural": 1.0,
    "slow": 0.85,
}

# Internal/system phrases rendered alongside the user-selectable variants.
# Keep in sync with GreetingCatalog::SYSTEM_PHRASES on the Ruby side.
SYSTEM_PHRASES = {
    "clarify": "Scusa, non ho capito bene. Per favore, dimmi più precisamente di cosa hai bisogno e perché stai chiamando.",
    "voicemail_prompt": "Va bene, dimmi pure quello che ti serve. Ti richiamo io.",
    "goodbye_spam": "Grazie per aver chiamato. Arrivederci.",
    "goodbye_short": "Arrivederci.",
    "no_answer": "Non ho ricevuto risposta. Arrivederci.",
}


class Variant(NamedTuple):
    slug: str
    text: str


def parse_catalog(path: Path) -> list[Variant]:
    """Extract slug + text pairs from the Ruby greeting_catalog.rb file.

    The catalog is plain Ruby with one Variant.new(...) per entry; we don't
    need to parse Ruby fully — just pull out slug: and text: arguments
    inside each Variant.new block.
    """
    src = path.read_text(encoding="utf-8")

    # Resolve EMAIL_PHONETIC interpolation if it's present (older catalogs
    # included the email inline; newer ones don't). Treat absence as empty.
    email_match = re.search(
        r'EMAIL_PHONETIC\s*=\s*"([^"]+)"',
        src,
    )
    email = email_match.group(1) if email_match else ""

    variants: list[Variant] = []
    # [\s\S]*? is lazy any-char incl. newlines — necessary because labels may
    # contain parentheses, so [^)] won't work.
    for block in re.finditer(
        r'Variant\.new\(\s*slug:\s*"([^"]+)"[\s\S]*?text:\s*"((?:[^"\\]|\\.)*)"',
        src,
    ):
        slug = block.group(1)
        # Decode common Ruby string escapes
        text = (
            block.group(2)
            .replace("\\n", "\n")
            .replace('\\"', '"')
            .replace("\\#", "#")
            .replace("#{EMAIL_PHONETIC}", email)
        )
        variants.append(Variant(slug=slug, text=text))

    if not variants:
        raise SystemExit(f"No variants parsed from {path}")
    return variants


def lang_code_for_voice(voice: str) -> str:
    """First letter of voice id encodes language: i=Italian, a=American, etc."""
    return voice[0] if voice else "a"


def render(variant: Variant, voice: str, tone: str, speed: float, pipeline_cache: dict, force: bool) -> bool:
    out_path = OUTPUT_ROOT / variant.slug / voice / f"{tone}.wav"
    if out_path.exists() and not force:
        print(f"  ✓ {out_path.relative_to(CALLSCREEN_ROOT)} (exists)", file=sys.stderr)
        return False

    out_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        import numpy as np
        import soundfile as sf
        from kokoro import KPipeline
    except ImportError as e:
        raise SystemExit(
            f"Missing dependency: {e}\n\n"
            "Install Kokoro first:\n"
            "  pip install 'kokoro>=0.9.4' soundfile torch numpy"
        )

    lang = lang_code_for_voice(voice)
    if lang not in pipeline_cache:
        pipeline_cache[lang] = KPipeline(lang_code=lang)
    pipeline = pipeline_cache[lang]
    voice_tensor = pipeline.load_voice(voice)

    pieces: list = []
    for _gs, _ps, audio in pipeline(variant.text, voice=voice_tensor, speed=speed):
        pieces.append(audio)
    if not pieces:
        raise RuntimeError(f"No audio generated for {variant.slug} / {voice} / {tone}")

    combined = np.concatenate(pieces)
    sf.write(str(out_path), combined, SAMPLE_RATE)
    print(
        f"  → {out_path.relative_to(CALLSCREEN_ROOT)} "
        f"(speed {speed}, {len(combined) / SAMPLE_RATE:.1f}s)",
        file=sys.stderr,
    )
    return True


def parse_csv(value: str | None, default: Iterable[str]) -> list[str]:
    if not value:
        return list(default)
    return [v.strip() for v in value.split(",") if v.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variants", help="Comma-separated phrase slugs to render (default: all)")
    parser.add_argument(
        "--voices",
        default=",".join(DEFAULT_VOICES),
        help=f"Comma-separated voice ids (default: {','.join(DEFAULT_VOICES)})",
    )
    parser.add_argument(
        "--tones",
        default=",".join(DEFAULT_TONES.keys()),
        help=f"Comma-separated tone slugs (default: {','.join(DEFAULT_TONES.keys())})",
    )
    parser.add_argument("--force", action="store_true", help="Re-render even if file exists")
    args = parser.parse_args()

    catalog = parse_catalog(CATALOG_FILE)
    # Append system phrases as additional Variants — same render path,
    # but they're internal and don't appear in the admin UI catalog.
    catalog = catalog + [Variant(slug=slug, text=text) for slug, text in SYSTEM_PHRASES.items()]
    catalog_by_slug = {v.slug: v for v in catalog}
    default_slugs = [v.slug for v in catalog]
    requested_slugs = parse_csv(args.variants, default_slugs)
    voices = parse_csv(args.voices, DEFAULT_VOICES)
    tones = parse_csv(args.tones, list(DEFAULT_TONES.keys()))

    unknown = [s for s in requested_slugs if s not in catalog_by_slug]
    if unknown:
        raise SystemExit(f"Unknown variants: {unknown}. Known: {list(catalog_by_slug)}")
    unknown_tones = [t for t in tones if t not in DEFAULT_TONES]
    if unknown_tones:
        raise SystemExit(f"Unknown tones: {unknown_tones}. Known: {list(DEFAULT_TONES)}")

    pipeline_cache: dict = {}
    rendered = 0
    skipped = 0
    total = len(requested_slugs) * len(voices) * len(tones)
    print(f"Rendering {len(requested_slugs)} phrases × {len(voices)} voices × "
          f"{len(tones)} tones = {total} files into {OUTPUT_ROOT}", file=sys.stderr)
    for slug in requested_slugs:
        variant = catalog_by_slug[slug]
        for voice in voices:
            for tone in tones:
                speed = DEFAULT_TONES[tone]
                if render(variant, voice, tone, speed, pipeline_cache, force=args.force):
                    rendered += 1
                else:
                    skipped += 1

    print(f"\nDone: {rendered} rendered, {skipped} skipped (use --force to overwrite)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
