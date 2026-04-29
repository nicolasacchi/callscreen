class GreetingCatalog
  Variant = Struct.new(:slug, :label, :text, keyword_init: true)

  EMAIL_PHONETIC = "operator at example dot com".freeze

  VARIANTS = [
    Variant.new(
      slug: "formal_lei",
      label: "Formale (Lei)",
      text: "Buongiorno. In questo momento sono impegnato. La prego di lasciare un messaggio dicendo di cosa ha bisogno: se necessario la richiamerò. In alternativa può scrivermi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "informal_tu",
      label: "Informale (tu)",
      text: "Ciao, sono impegnato. Dimmi di cosa hai bisogno dopo il segnale e ti richiamerò se serve. Oppure scrivimi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "business_meeting",
      label: "In riunione",
      text: "Buongiorno, al momento sono in riunione. La prego di lasciare un messaggio con il motivo della chiamata: la richiamerò appena libero. Per messaggi scritti: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "brief_lei",
      label: "Breve (Lei)",
      text: "Salve, sono impegnato. Mi dica di cosa ha bisogno e la richiamo. Email: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "brief_tu",
      label: "Breve (tu)",
      text: "Ciao, sono impegnato. Dimmi di cosa hai bisogno e ti richiamo. Email: #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "apologetic",
      label: "Scuse cortesi",
      text: "Mi scusi, in questo momento non posso rispondere. Mi spieghi brevemente cosa le serve e la richiamerò io. Può anche scrivermi a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "direct",
      label: "Diretto",
      text: "Pronto, sono impegnato. Dica chi è e di cosa ha bisogno. Se è urgente richiamo io, altrimenti scriva a #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "warm",
      label: "Caloroso",
      text: "Ciao! Grazie per aver chiamato. Adesso non posso rispondere, ma se mi dici di cosa hai bisogno ti richiamo volentieri. La mia email è #{EMAIL_PHONETIC}."
    ),
    Variant.new(
      slug: "email_first",
      label: "Email come canale primario",
      text: "Salve, sono impegnato. Per la maggior parte delle richieste è più veloce scrivere a #{EMAIL_PHONETIC}. Se preferisce, lasci pure un messaggio e la richiamerò."
    ),
    Variant.new(
      slug: "bilingual_short",
      label: "Italiano + English",
      text: "Sono impegnato. Lasciate un messaggio o scrivete a #{EMAIL_PHONETIC}. Hi, I'm busy. Please leave a message or write to operator at example dot com."
    )
  ].freeze

  SLUGS = VARIANTS.map(&:slug).freeze

  def self.find(slug)
    VARIANTS.find { |v| v.slug == slug.to_s }
  end

  def self.text_for(slug)
    find(slug)&.text
  end
end
