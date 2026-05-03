#!/usr/bin/env python3
"""Side-by-side TTS comparison for callscreen greetings.

Renders one phrase from app/models/greeting_catalog.rb with up to three
engines (Kokoro, Chatterbox, F5) so you can listen to all of them and
pick. Output goes to tmp/voice_compare/.

Usage:

    bin/voice_compare informal_tu                 # Italian (default)
    bin/voice_compare goodbye_spam --lang en      # English
    bin/voice_compare informal_tu --reference ~/me.wav
                                                  # Chatterbox/F5 use this
                                                  # 10-30s sample as the
                                                  # cloning reference

Engines that aren't installed are skipped with a one-line install hint.
Outputs:

    tmp/voice_compare/
        informal_tu_kokoro_if_sara_natural.wav
        informal_tu_chatterbox_default_natural.wav
        informal_tu_chatterbox_clone_natural.wav     (when --reference given)
        informal_tu_f5_clone_natural.wav             (when --reference given)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CALLSCREEN_ROOT = Path(__file__).resolve().parent.parent
CATALOG_FILE = CALLSCREEN_ROOT / "app" / "models" / "greeting_catalog.rb"
OUTPUT_ROOT = CALLSCREEN_ROOT / "tmp" / "voice_compare"
SAMPLE_RATE = 24000

# Default voices per engine (matches what's already pre-rendered for Kokoro).
KOKORO_VOICES = {"it": "if_sara", "en": "af_heart"}
CHATTERBOX_LANG_ID = {"it": "it", "en": "en"}


def parse_phrase(slug: str, lang: str) -> str:
    """Extract a single phrase's text from greeting_catalog.rb."""
    src = CATALOG_FILE.read_text(encoding="utf-8")

    # Variants
    block_re = re.compile(
        r'Variant\.new\(\s*'
        r'slug:\s*"' + re.escape(slug) + r'"[\s\S]*?'
        r'text_by_language:\s*\{([\s\S]*?)\}',
        re.MULTILINE,
    )
    m = block_re.search(src)
    if m:
        body = m.group(1)
    else:
        # SYSTEM_PHRASES fallback
        sp_re = re.compile(
            r'"' + re.escape(slug) + r'"\s*=>\s*\{([\s\S]*?)\}',
            re.MULTILINE,
        )
        sm = sp_re.search(src)
        if not sm:
            raise SystemExit(f"Unknown phrase slug: {slug!r}")
        body = sm.group(1)

    pair_re = re.compile(r'"(it|en)"\s*=>\s*"((?:[^"\\]|\\.)*)"')
    texts = {}
    for pair in pair_re.finditer(body):
        texts[pair.group(1)] = pair.group(2).replace("\\n", "\n").replace('\\"', '"')

    text = texts.get(lang) or texts.get("it") or next(iter(texts.values()))
    return text


def render_kokoro(text: str, lang: str, slug: str) -> Path | None:
    try:
        import numpy as np
        import soundfile as sf
        from kokoro import KPipeline
    except ImportError:
        print("  ✗ Kokoro not installed — skipping. Install: pip install 'kokoro>=0.9.4'",
              file=sys.stderr)
        return None

    voice = KOKORO_VOICES[lang]
    lang_code = "i" if lang == "it" else "a"
    pipe = KPipeline(lang_code=lang_code)
    voice_tensor = pipe.load_voice(voice)
    pieces = []
    for _gs, _ps, audio in pipe(text, voice=voice_tensor, speed=1.0):
        pieces.append(audio)
    if not pieces:
        return None
    combined = np.concatenate(pieces)
    out = OUTPUT_ROOT / f"{slug}_kokoro_{voice}_natural.wav"
    sf.write(str(out), combined, SAMPLE_RATE)
    print(f"  ✓ Kokoro / {voice}: {out.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
    return out


def render_chatterbox(text: str, lang: str, slug: str, reference: Path | None) -> list[Path]:
    """Render with Chatterbox. Two outputs:
       - default-voice (no reference)
       - cloned-voice (when reference provided)
    """
    try:
        import torch
        import torchaudio as ta
    except ImportError:
        print("  ✗ Chatterbox prereq (torch/torchaudio) missing — skipping",
              file=sys.stderr)
        return []
    try:
        from chatterbox.tts import ChatterboxTTS
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS
    except ImportError:
        print("  ✗ Chatterbox not installed — skipping. Install: pip install chatterbox-tts",
              file=sys.stderr)
        return []

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"  loading Chatterbox on {device}…", file=sys.stderr)

    outputs: list[Path] = []

    # Pick model: English uses Standard (best quality + emotion control);
    # Italian uses Multilingual.
    if lang == "en":
        model = ChatterboxTTS.from_pretrained(device=device)
        flavor = "standard"
        gen_kwargs_default = {"exaggeration": 0.3, "cfg_weight": 0.7}
    else:
        model = ChatterboxMultilingualTTS.from_pretrained(device=device)
        flavor = "multilingual"
        gen_kwargs_default = {
            "exaggeration": 0.3, "cfg_weight": 0.7,
            "language_id": CHATTERBOX_LANG_ID[lang],
        }
    sr = model.sr

    # Default-voice rendering (no reference)
    wav = model.generate(text, **gen_kwargs_default)
    out = OUTPUT_ROOT / f"{slug}_chatterbox_{flavor}_natural.wav"
    ta.save(str(out), wav, sr)
    print(f"  ✓ Chatterbox {flavor} (default): {out.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
    outputs.append(out)

    # Cloned-voice rendering (when reference given)
    if reference and reference.exists():
        kw = dict(gen_kwargs_default)
        kw["audio_prompt_path"] = str(reference)
        wav_clone = model.generate(text, **kw)
        out_clone = OUTPUT_ROOT / f"{slug}_chatterbox_{flavor}_clone_natural.wav"
        ta.save(str(out_clone), wav_clone, sr)
        print(f"  ✓ Chatterbox {flavor} (cloned from {reference.name}): "
              f"{out_clone.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
        outputs.append(out_clone)

    return outputs


def render_f5(text: str, lang: str, slug: str, reference: Path | None) -> Path | None:
    if not reference:
        print("  ✗ F5-TTS skipped — requires a --reference WAV", file=sys.stderr)
        return None
    if not reference.exists():
        print(f"  ✗ F5-TTS reference not found: {reference}", file=sys.stderr)
        return None

    try:
        import soundfile as sf
        from f5_tts.api import F5TTS
        import torch
    except ImportError:
        print("  ✗ F5-TTS not installed — skipping. Install: pip install f5-tts",
              file=sys.stderr)
        return None

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"  loading F5-TTS on {device}…", file=sys.stderr)
    model = F5TTS(device=device)

    # F5 needs a transcription of the reference audio. For comparison
    # purposes we just use a generic placeholder — quality is reduced but
    # the relative comparison is still useful.
    placeholder_ref_text = ("This is a sample of my voice for cloning."
                            if lang == "en"
                            else "Questa è una mia registrazione per la clonazione.")

    wav, sr, _ = model.infer(
        ref_file=str(reference),
        ref_text=placeholder_ref_text,
        gen_text=text,
        seed=42,
    )
    out = OUTPUT_ROOT / f"{slug}_f5_clone_natural.wav"
    sf.write(str(out), wav, sr)
    print(f"  ✓ F5-TTS (cloned from {reference.name}): "
          f"{out.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("phrase",
                        help="Phrase slug from greeting_catalog.rb (e.g. informal_tu, "
                             "goodbye_spam, voicemail_prompt)")
    parser.add_argument("--lang", default="it", choices=["it", "en"],
                        help="Language: it (default) or en")
    parser.add_argument("--reference", type=Path,
                        help="Path to a 10-30s WAV/MP3 sample of YOUR voice. "
                             "Required for Chatterbox cloning + F5-TTS.")
    parser.add_argument("--engines", default="kokoro,chatterbox,f5",
                        help="Comma-separated engine subset (default: all)")
    args = parser.parse_args()

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    text = parse_phrase(args.phrase, args.lang)
    print(f"\nPhrase ({args.lang}): {text!r}\n", file=sys.stderr)
    print(f"Output dir: {OUTPUT_ROOT.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
    print(file=sys.stderr)

    engines = [e.strip() for e in args.engines.split(",") if e.strip()]
    if "kokoro" in engines:
        render_kokoro(text, args.lang, args.phrase)
    if "chatterbox" in engines:
        render_chatterbox(text, args.lang, args.phrase, args.reference)
    if "f5" in engines:
        render_f5(text, args.lang, args.phrase, args.reference)

    print("\nDone. Listen with:", file=sys.stderr)
    print(f"  ls -1 {OUTPUT_ROOT.relative_to(CALLSCREEN_ROOT)}/{args.phrase}_*", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
