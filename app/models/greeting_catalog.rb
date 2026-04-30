class GreetingCatalog
  Variant = Struct.new(:slug, :label, :text, keyword_init: true)

  EMAIL_PHONETIC = "operator at example dot com".freeze
  EMAIL_PHONETIC_EN = "operator at example dot com".freeze

  # === Phrases (the textual greeting) ===
  VARIANTS = [
    Variant.new(
      slug: "formal_lei",
      label: "Formal address (Lei)",
      text: "Buongiorno. In questo momento sono impegnato. La prego di lasciare un messaggio dicendo di cosa ha bisogno: se necessario la richiamerò. In alternativa può scrivermi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "informal_tu",
      label: "Informal address (tu)",
      text: "Ciao, sono impegnato. Dimmi di cosa hai bisogno dopo il segnale e ti richiamerò se serve. Oppure scrivimi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "business_meeting",
      label: "In a meeting",
      text: "Buongiorno, al momento sono in riunione. La prego di lasciare un messaggio con il motivo della chiamata: la richiamerò appena libero. Per messaggi scritti: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "brief_lei",
      label: "Short, formal",
      text: "Salve, sono impegnato. Mi dica di cosa ha bisogno e la richiamo. Email: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "brief_tu",
      label: "Short, informal",
      text: "Ciao, sono impegnato. Dimmi di cosa hai bisogno e ti richiamo. Email: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "apologetic",
      label: "Apologetic",
      text: "Mi scusi, in questo momento non posso rispondere. Mi spieghi brevemente cosa le serve e la richiamerò io. Può anche scrivermi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "direct",
      label: "Direct, no apology",
      text: "Pronto, sono impegnato. Dica chi è e di cosa ha bisogno. Se è urgente richiamo io, altrimenti scriva a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "warm",
      label: "Warm, friendly",
      text: "Ciao! Grazie per aver chiamato. Adesso non posso rispondere, ma se mi dici di cosa hai bisogno ti richiamo volentieri. La mia email è #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "email_first",
      label: "Email-first",
      text: "Salve, sono impegnato. Per la maggior parte delle richieste è più veloce scrivere a #{EMAIL_PHONETIC}. Se preferisce, lasci pure un messaggio e la richiamerò."
    ),
    Variant.new(
      slug: "bilingual_short",
      label: "Italian + English",
      text: "Sono impegnato. Lasciate un messaggio o scrivete a #{EMAIL_PHONETIC}. Hi, I'm busy. Please leave a message or write to #{EMAIL_PHONETIC_EN}."
    )
  ].freeze

  SLUGS = VARIANTS.map(&:slug).freeze

  # System phrases — internal use, not selectable from the admin UI.
  # Pre-rendered alongside variants under storage/greetings/<slug>/<voice>/<tone>.wav.
  # Falls back to Telnyx <Say voice="alice"> with the same text if the audio
  # file is missing.
  SYSTEM_PHRASES = {
    "clarify" => "Scusa, non ho capito bene. Per favore, dimmi più precisamente di cosa hai bisogno e perché stai chiamando.",
    "voicemail_prompt" => "Va bene, dimmi pure quello che ti serve. Ti richiamo io.",
    "goodbye_spam" => "Grazie per aver chiamato. Arrivederci.",
    "goodbye_short" => "Arrivederci.",
    "no_answer" => "Non ho ricevuto risposta. Arrivederci."
  }.freeze

  ALL_SLUGS = (SLUGS + SYSTEM_PHRASES.keys).freeze

  # === Voices (who is speaking) ===
  # Each value is a label that describes WHAT the voice is, not a person's name.
  VOICES = {
    "if_sara"   => "Italian female (warm)",
    "im_nicola" => "Italian male (calm)"
  }.freeze

  VOICE_SLUGS = VOICES.keys.freeze

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

  def self.text_for(slug)
    find(slug)&.text
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
end
