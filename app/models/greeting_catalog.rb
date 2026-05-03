class GreetingCatalog
  # Each variant carries text in BOTH supported languages. The screener
  # picks the matching one at call time based on the caller's number
  # (E.164 +39 prefix → Italian; everything else → English).
  Variant = Struct.new(:slug, :label, :text_by_language, keyword_init: true) do
    def text(lang)
      text_by_language[lang.to_s] || text_by_language["it"] || text_by_language.values.first
    end
  end

  # === Phrases (the textual greeting) ===
  # All 10 variants are pure invitations to leave a voicemail.
  VARIANTS = [
    Variant.new(
      slug: "formal_lei",
      label: "Formal address (Lei)",
      text_by_language: {
        "it" => "Buongiorno. In questo momento sono impegnato. La prego di lasciare un messaggio dicendo di cosa ha bisogno: se necessario la richiamerò.",
        "en" => "Good day. I'm currently busy. Please leave a message stating what you need; I will call you back if necessary."
      }
    ),
    Variant.new(
      slug: "informal_tu",
      label: "Informal address (tu)",
      text_by_language: {
        "it" => "Ciao, sono impegnato. Dimmi di cosa hai bisogno e ti richiamerò se serve.",
        "en" => "Hi, I'm busy right now. Tell me what you need and I'll call you back if it matters."
      }
    ),
    Variant.new(
      slug: "business_meeting",
      label: "In a meeting",
      text_by_language: {
        "it" => "Buongiorno, al momento sono in riunione. La prego di lasciare un messaggio con il motivo della chiamata: la richiamerò appena libero.",
        "en" => "Hello, I'm in a meeting right now. Please leave a message with the reason for your call; I'll call you back as soon as I'm free."
      }
    ),
    Variant.new(
      slug: "brief_lei",
      label: "Short, formal",
      text_by_language: {
        "it" => "Salve, sono impegnato. Mi dica di cosa ha bisogno e la richiamo.",
        "en" => "Hello, I'm busy. Tell me what you need and I'll call you back."
      }
    ),
    Variant.new(
      slug: "brief_tu",
      label: "Short, informal",
      text_by_language: {
        "it" => "Ciao, sono impegnato. Dimmi di cosa hai bisogno e ti richiamo.",
        "en" => "Hi, I'm busy. Tell me what you need and I'll call you back."
      }
    ),
    Variant.new(
      slug: "apologetic",
      label: "Apologetic",
      text_by_language: {
        "it" => "Mi scusi, in questo momento non posso rispondere. Mi spieghi brevemente cosa le serve e la richiamerò io.",
        "en" => "Sorry, I can't pick up right now. Briefly tell me what you need and I'll call you back."
      }
    ),
    Variant.new(
      slug: "direct",
      label: "Direct, no apology",
      text_by_language: {
        "it" => "Pronto, sono impegnato. Dica chi è e di cosa ha bisogno. Se è urgente la richiamo io.",
        "en" => "Hello, I'm busy. State your name and what you need. If it's urgent I'll call you back."
      }
    ),
    Variant.new(
      slug: "warm",
      label: "Warm, friendly",
      text_by_language: {
        "it" => "Ciao! Grazie per aver chiamato. Adesso non posso rispondere, ma se mi dici di cosa hai bisogno ti richiamo volentieri.",
        "en" => "Hi there! Thanks for calling. I can't answer right now, but if you tell me what you need I'll be glad to call you back."
      }
    ),
    Variant.new(
      slug: "delegate_voicemail",
      label: "Delegate to voicemail",
      text_by_language: {
        "it" => "Salve, sono impegnato. La invito a lasciare un breve messaggio specificando di cosa ha bisogno: la richiamerò quanto prima.",
        "en" => "Hello, I'm busy. Please leave a brief message stating what you need; I'll call you back as soon as possible."
      }
    ),
    Variant.new(
      slug: "bilingual_short",
      label: "Italian + English",
      text_by_language: {
        "it" => "Sono impegnato, lasciate un messaggio. Hi, I'm busy, please leave a message.",
        "en" => "I'm busy, please leave a message. Sono impegnato, lasciate un messaggio."
      }
    )
  ].freeze

  SLUGS = VARIANTS.map(&:slug).freeze

  # System phrases — internal use, not selectable from the admin UI.
  # Pre-rendered alongside variants under storage/greetings/<slug>/<voice>/<tone>.wav.
  # Falls back to Telnyx <Say voice="alice"> with the same text if the audio
  # file is missing.
  SYSTEM_PHRASES = {
    "clarify" => {
      "it" => "Scusa, non ho capito bene. Per favore, dimmi più precisamente di cosa hai bisogno e perché stai chiamando.",
      "en" => "Sorry, I didn't catch that. Please tell me more clearly what you need and why you're calling."
    },
    "voicemail_prompt" => {
      "it" => "Va bene, dimmi pure quello che ti serve. Ti richiamo io.",
      "en" => "OK, tell me what you need. I'll call you back."
    },
    "goodbye_spam" => {
      "it" => "Grazie per aver chiamato. Arrivederci.",
      "en" => "Thanks for calling. Goodbye."
    },
    "goodbye_short" => {
      "it" => "Arrivederci.",
      "en" => "Goodbye."
    },
    "no_answer" => {
      "it" => "Non ho ricevuto risposta. Arrivederci.",
      "en" => "I didn't get a response. Goodbye."
    }
  }.freeze

  ALL_SLUGS = (SLUGS + SYSTEM_PHRASES.keys).freeze

  # === Voices (who is speaking) ===
  # Each voice id encodes language in its first letter:
  #   i = Italian   (if_*, im_*)   only Kokoro language with Italian L1 voices
  #   a = American  (af_*, am_*)
  #   b = British   (bf_*, bm_*)
  # Voices are paired across languages so the screener can swap automatically:
  # an Italian "warm female" caller-experience pairs to af_heart for an
  # English caller, etc.
  VOICES = {
    "if_sara"    => "Italian female (warm)",
    "im_nicola"  => "Italian male (calm)",
    "af_heart"   => "English female (warm)",
    "am_michael" => "English male (calm)"
  }.freeze

  VOICE_SLUGS = VOICES.keys.freeze

  # Voice equivalents across languages. Used to auto-swap voice based on
  # the caller's language. Italian voices map to their English counterpart
  # of matching gender+tone; English voices map back to Italian similarly.
  VOICE_LANGUAGE_PAIRS = {
    "if_sara"    => { "it" => "if_sara",    "en" => "af_heart"   },
    "im_nicola"  => { "it" => "im_nicola",  "en" => "am_michael" },
    "af_heart"   => { "it" => "if_sara",    "en" => "af_heart"   },
    "am_michael" => { "it" => "im_nicola",  "en" => "am_michael" },
    # Telnyx fallback voices map to the same English voice — they're
    # not pre-rendered, so the controller falls back to Telnyx's
    # built-in `alice` regardless.
    "alice"      => { "it" => "if_sara",    "en" => "af_heart"   },
    "man"        => { "it" => "im_nicola",  "en" => "am_michael" },
    "woman"      => { "it" => "if_sara",    "en" => "af_heart"   }
  }.freeze

  # === Tones (delivery pace / mood, mapped to Kokoro speed parameter) ===
  TONES = {
    "natural" => { speed: 1.0,  label: "Natural pace" },
    "slow"    => { speed: 0.85, label: "Slow & clear" }
  }.freeze

  TONE_SLUGS = TONES.keys.freeze

  # === Lookup helpers ===

  def self.find(slug)
    VARIANTS.find { |v| v.slug == slug.to_s }
  end

  def self.text_for(slug, language: "it")
    variant = find(slug)
    return variant.text(language) if variant
    SYSTEM_PHRASES.dig(slug.to_s, language.to_s) ||
      SYSTEM_PHRASES.dig(slug.to_s, "it")
  end

  # Pick the voice id appropriate for the caller's language. Falls back to
  # the original voice if no mapping is registered (e.g. caller picked a
  # custom voice we don't know about).
  def self.voice_for_language(voice_slug, language)
    pair = VOICE_LANGUAGE_PAIRS[voice_slug.to_s]
    return voice_slug.to_s unless pair
    pair[language.to_s] || voice_slug.to_s
  end

  def self.voice_label(slug)
    VOICES[slug.to_s] || slug.to_s
  end

  def self.tone_label(slug)
    TONES.dig(slug.to_s, :label) || slug.to_s
  end

  def self.tone_speed(slug)
    TONES.dig(slug.to_s, :speed) || 1.0
  end

  # Maps an E.164 caller number to a language code. Italian dialing prefix
  # → Italian; anything else → English. Used by the controller to pick
  # the right greeting + voice + Whisper language.
  def self.language_for_number(from_number)
    from_number.to_s.start_with?("+39") ? "it" : "en"
  end
end
