#!/usr/bin/env python3
"""Render a SINGLE phrase × voice × tone into the greeting storage tree.

Used by PhraseRenderJob to incrementally render user-authored phrases.
Reuses the same Kokoro / Chatterbox / atempo pipeline from
render_greetings.py — no duplicate TTS code.

Usage:
    python3 scripts/render_phrase.py \\
        --slug ti_chiamo_dopo_pranzo \\
        --text-it "Ciao, ti chiamo dopo pranzo." \\
        --text-en "Hi, I'll call you back after lunch." \\
        --voice im_nicola \\
        --tone natural \\
        --out storage/greetings/ti_chiamo_dopo_pranzo/im_nicola/natural.wav
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from types import SimpleNamespace

# Re-use helpers from the bulk renderer.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import render_greetings  # noqa: E402  (sibling script in same dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slug",   required=True)
    parser.add_argument("--label",  default="")
    parser.add_argument("--text-it", default="")
    parser.add_argument("--text-en", default="")
    parser.add_argument("--voice",  required=True)
    parser.add_argument("--tone",   required=True, choices=("natural", "slow"))
    parser.add_argument("--out",    required=True, help="Absolute output path")
    args = parser.parse_args()

    text_by_language = {}
    if args.text_it:
        text_by_language["it"] = args.text_it
    if args.text_en:
        text_by_language["en"] = args.text_en
    if not text_by_language:
        print("ERROR: at least one of --text-it / --text-en required", file=sys.stderr)
        return 2

    # Build a Variant-shaped object and call the bulk renderer's
    # internals directly. Tone speed mirrors GreetingCatalog::TONES.
    variant = SimpleNamespace(slug=args.slug, text_by_language=text_by_language)
    speed = 1.0 if args.tone == "natural" else 0.85

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    text_lang = render_greetings.text_language_for_voice(args.voice)
    text = text_by_language.get(text_lang) or text_by_language.get("it") or text_by_language.get("en")
    if not text:
        print(f"ERROR: no text in {text_lang} for slug {args.slug}", file=sys.stderr)
        return 2

    pipeline_cache: dict = {}
    if render_greetings.is_chatterbox_voice(args.voice):
        ok = render_greetings._render_chatterbox(
            out_path, args.voice, text, text_lang, args.tone, speed, pipeline_cache
        )
    else:
        ok = render_greetings._render_kokoro(
            out_path, args.voice, text, text_lang, args.tone, speed, pipeline_cache
        )

    if not ok:
        print(f"ERROR: render returned False for {args.slug}/{args.voice}/{args.tone}", file=sys.stderr)
        return 1

    print(f"RENDERED {args.slug} {args.voice} {args.tone} -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
