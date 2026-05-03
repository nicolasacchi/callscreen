#!/usr/bin/env python3
"""Render the 10 greeting variants × N voices into storage/greetings/<slug>/<voice>.wav.

Each variant carries text in BOTH languages (it/en); the script picks the
matching text based on the voice's language prefix (i=Italian, a/b=English).

Uses Kokoro TTS directly (the same engine the meditation project at
upstream TTS project uses). Installation:

    pip install 'kokoro>=0.9.4' soundfile torch

Or, if you already have meditation's venv with the [kokoro] extra:

    cd ~/project/vibe/meditation && pip install -e '.[kokoro]'

Then run from the callscreen project root:

    python3 scripts/render_greetings.py
    python3 scripts/render_greetings.py --voices if_sara,af_heart
    python3 scripts/render_greetings.py --variants informal_tu,direct --force

Output is 24 kHz mono WAV. Telnyx's playback_start accepts WAV directly.
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

# Default voice set covers both languages, gendered:
#   Italian: if_sara (female), im_nicola (male)
#   English: af_heart (female), am_michael (male)
DEFAULT_VOICES = ["if_sara", "im_nicola", "af_heart", "am_michael"]

# Map tone slug → Kokoro speed multiplier. Keep in sync with
# GreetingCatalog::TONES on the Ruby side.
DEFAULT_TONES = {
    "natural": 1.0,
    "slow": 0.85,
}

# Internal/system phrases rendered alongside the user-selectable variants.
# Keep in sync with GreetingCatalog::SYSTEM_PHRASES on the Ruby side.
SYSTEM_PHRASES = {
    "clarify": {
        "it": "Scusa, non ho capito bene. Per favore, dimmi più precisamente di cosa hai bisogno e perché stai chiamando.",
        "en": "Sorry, I didn't catch that. Please tell me more clearly what you need and why you're calling.",
    },
    "voicemail_prompt": {
        "it": "Va bene, dimmi pure quello che ti serve. Ti richiamo io.",
        "en": "OK, tell me what you need. I'll call you back.",
    },
    "goodbye_spam": {
        "it": "Grazie per aver chiamato. Arrivederci.",
        "en": "Thanks for calling. Goodbye.",
    },
    "goodbye_short": {
        "it": "Arrivederci.",
        "en": "Goodbye.",
    },
    "no_answer": {
        "it": "Non ho ricevuto risposta. Arrivederci.",
        "en": "I didn't get a response. Goodbye.",
    },
}


class Variant(NamedTuple):
    slug: str
    text_by_language: dict


def parse_catalog(path: Path) -> list[Variant]:
    """Extract slug + text-per-language from the Ruby greeting_catalog.rb file."""
    src = path.read_text(encoding="utf-8")

    variants: list[Variant] = []
    # Find each Variant.new block and extract slug + text_by_language entries.
    # The text_by_language hash has shape: { "it" => "…", "en" => "…" }.
    block_re = re.compile(
        r'Variant\.new\(\s*'
        r'slug:\s*"([^"]+)"[\s\S]*?'
        r'text_by_language:\s*\{([\s\S]*?)\}',
        re.MULTILINE,
    )
    pair_re = re.compile(r'"(it|en)"\s*=>\s*"((?:[^"\\]|\\.)*)"')

    for m in block_re.finditer(src):
        slug = m.group(1)
        body = m.group(2)
        texts: dict = {}
        for pair in pair_re.finditer(body):
            lang = pair.group(1)
            text = (
                pair.group(2)
                .replace("\\n", "\n")
                .replace('\\"', '"')
                .replace("\\#", "#")
            )
            texts[lang] = text
        if texts:
            variants.append(Variant(slug=slug, text_by_language=texts))

    if not variants:
        raise SystemExit(f"No variants parsed from {path}")
    return variants


def lang_code_for_voice(voice: str) -> str:
    """First letter of voice id encodes language: i=Italian, a=American, b=British."""
    if not voice:
        return "a"
    prefix = voice[0]
    # Both American (a) and British (b) Kokoro pipelines speak English.
    return prefix if prefix in "abefhijpz" else "a"


def text_language_for_voice(voice: str) -> str:
    """Pick the catalog text language: 'it' for Italian voices, 'en' for English."""
    return "it" if lang_code_for_voice(voice) == "i" else "en"


def render(variant: Variant, voice: str, tone: str, speed: float, pipeline_cache: dict, force: bool) -> bool:
    out_path = OUTPUT_ROOT / variant.slug / voice / f"{tone}.wav"
    if out_path.exists() and not force:
        print(f"  ✓ {out_path.relative_to(CALLSCREEN_ROOT)} (exists)", file=sys.stderr)
        return False

    text_lang = text_language_for_voice(voice)
    text = variant.text_by_language.get(text_lang) or variant.text_by_language.get("it")
    if not text:
        print(f"  ✗ no text for {variant.slug} in language {text_lang} — skipping", file=sys.stderr)
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
    for _gs, _ps, audio in pipeline(text, voice=voice_tensor, speed=speed):
        pieces.append(audio)
    if not pieces:
        raise RuntimeError(f"No audio generated for {variant.slug} / {voice} / {tone}")

    combined = np.concatenate(pieces)
    sf.write(str(out_path), combined, SAMPLE_RATE)
    print(
        f"  → {out_path.relative_to(CALLSCREEN_ROOT)} "
        f"(lang={text_lang}, speed {speed}, {len(combined) / SAMPLE_RATE:.1f}s)",
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
    # Append system phrases as additional Variants — same render path.
    catalog = catalog + [Variant(slug=slug, text_by_language=texts) for slug, texts in SYSTEM_PHRASES.items()]
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
