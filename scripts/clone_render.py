#!/usr/bin/env python3
"""Clone a tenant's voice and render the full greeting catalog.

Reads the tenant's uploaded voice sample from
storage/voice_samples/<sample_path> and uses Chatterbox to render every
phrase from app/models/greeting_catalog.rb (variants + system phrases) in
both languages × both tones into:

    storage/greetings/<slug>/_t<tenant_id>/<tone>.wav

After rendering, prints `RENDERED <tenant_id>` so the calling Ruby job
can mark the tenant as rendered. Exits non-zero on failure.

Usage (from the host, where Chatterbox is installed):

    bin/clone_render <tenant_id>

Or directly:

    .venv/bin/python scripts/clone_render.py <tenant_id> \
        --sample storage/voice_samples/tenant_3.wav

If --sample is omitted, the script looks up the tenant's voice_sample_path
via the Rails DB (requires the Rails environment).
"""
from __future__ import annotations

import argparse
import re
import sys
import sqlite3
from pathlib import Path

CALLSCREEN_ROOT = Path(__file__).resolve().parent.parent
CATALOG_FILE = CALLSCREEN_ROOT / "app" / "models" / "greeting_catalog.rb"
GREETINGS_DIR = CALLSCREEN_ROOT / "storage" / "greetings"
SAMPLES_DIR = CALLSCREEN_ROOT / "storage" / "voice_samples"
DEV_DB = CALLSCREEN_ROOT / "storage" / "development.sqlite3"

# Language → Chatterbox language_id (Multilingual model)
LANG_ID = {"it": "it", "en": "en"}

DEFAULT_TONES = {"natural": 1.0, "slow": 0.85}

# System phrases — keep in sync with GreetingCatalog::SYSTEM_PHRASES
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


def parse_catalog(path: Path) -> dict[str, dict[str, str]]:
    """Returns {slug: {lang: text}} for all variants in the catalog."""
    src = path.read_text(encoding="utf-8")
    block_re = re.compile(
        r'Variant\.new\(\s*'
        r'slug:\s*"([^"]+)"[\s\S]*?'
        r'text_by_language:\s*\{([\s\S]*?)\}',
        re.MULTILINE,
    )
    pair_re = re.compile(r'"(it|en)"\s*=>\s*"((?:[^"\\]|\\.)*)"')
    out: dict = {}
    for block in block_re.finditer(src):
        slug = block.group(1)
        body = block.group(2)
        texts: dict = {}
        for pair in pair_re.finditer(body):
            lang = pair.group(1)
            text = pair.group(2).replace("\\n", "\n").replace('\\"', '"')
            texts[lang] = text
        if texts:
            out[slug] = texts
    return out


def lookup_sample_from_db(tenant_id: int) -> str | None:
    """Best-effort SQLite lookup so we don't have to require Rails."""
    if not DEV_DB.exists():
        return None
    conn = sqlite3.connect(str(DEV_DB))
    try:
        cur = conn.execute(
            "SELECT voice_sample_path FROM tenants WHERE id = ?", (tenant_id,)
        )
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def render_all(tenant_id: int, sample_path: Path, dry_run: bool = False) -> int:
    if not sample_path.exists():
        print(f"FATAL: sample file not found: {sample_path}", file=sys.stderr)
        return 2

    try:
        import torch
        import torchaudio as ta
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS
    except ImportError as e:
        print(f"FATAL: Chatterbox not installed in this Python env: {e}", file=sys.stderr)
        print("       Install: pip install chatterbox-tts", file=sys.stderr)
        return 3

    catalog = parse_catalog(CATALOG_FILE)
    catalog.update(SYSTEM_PHRASES)
    cloned_dir = f"_t{tenant_id}"

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"loading Chatterbox Multilingual on {device}…", file=sys.stderr)
    model = ChatterboxMultilingualTTS.from_pretrained(device=device)
    sr = model.sr

    rendered = 0
    skipped = 0
    total_files = sum(len(texts) * len(DEFAULT_TONES) for texts in catalog.values())
    print(f"Rendering {len(catalog)} phrases × 2 langs × {len(DEFAULT_TONES)} tones "
          f"= {total_files} files into storage/greetings/<slug>/{cloned_dir}/", file=sys.stderr)

    for slug, texts in catalog.items():
        for lang, text in texts.items():
            if lang not in LANG_ID:
                continue
            for tone, _speed in DEFAULT_TONES.items():
                # Tone via exaggeration: slow = calmer (lower exaggeration);
                # natural = mid. Chatterbox doesn't have a direct speed knob,
                # so we approximate by adjusting cfg_weight and exaggeration.
                exaggeration = 0.25 if tone == "slow" else 0.35

                # Output path includes language in tone slug to disambiguate
                # since cloned voice doesn't encode language in name.
                # Actually: rendering both languages into same path would
                # collide. Use suffix to distinguish.
                tone_with_lang = tone if lang == "it" else f"{tone}_en"
                out = GREETINGS_DIR / slug / cloned_dir / f"{tone_with_lang}.wav"
                if dry_run:
                    print(f"  (dry) {out.relative_to(CALLSCREEN_ROOT)}", file=sys.stderr)
                    continue
                out.parent.mkdir(parents=True, exist_ok=True)
                try:
                    wav = model.generate(
                        text,
                        audio_prompt_path=str(sample_path),
                        exaggeration=exaggeration,
                        cfg_weight=0.7,
                        language_id=LANG_ID[lang],
                    )
                    ta.save(str(out), wav, sr)
                    print(f"  ✓ {out.relative_to(CALLSCREEN_ROOT)} ({lang})", file=sys.stderr)
                    rendered += 1
                except Exception as e:
                    print(f"  ✗ FAILED {out.relative_to(CALLSCREEN_ROOT)}: {e}", file=sys.stderr)
                    skipped += 1

    print(f"\nDone: {rendered} rendered, {skipped} failed", file=sys.stderr)
    if rendered > 0:
        print(f"RENDERED {tenant_id}")  # for the Ruby job to grep
    return 0 if skipped == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("tenant_id", type=int, help="Tenant.id")
    parser.add_argument("--sample", type=Path,
                        help="Path to sample WAV/MP3. If omitted, looked up via SQLite.")
    parser.add_argument("--dry-run", action="store_true",
                        help="List output paths without rendering")
    args = parser.parse_args()

    sample = args.sample
    if sample is None:
        sp = lookup_sample_from_db(args.tenant_id)
        if sp is None:
            print(f"FATAL: no voice_sample_path for tenant {args.tenant_id} in {DEV_DB}",
                  file=sys.stderr)
            return 2
        sample = SAMPLES_DIR / sp

    return render_all(args.tenant_id, sample, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
