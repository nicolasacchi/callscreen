class SeedSpamResponsePhrases < ActiveRecord::Migration[8.1]
  # Seeds the six system phrases used by the new spam-response modes
  # (polite_disclose / time_waster). Italian primary, English fallback.
  # Mirrors `populate_system_phrases.rb` (uses `insert_all` to bypass
  # the `after_commit` render hook), then explicitly enqueues
  # `PhraseRenderJob` so the WAVs render once on first deploy.

  PHRASES = [
    {
      slug:    "spam_disclose",
      label:   "Spam disclose (polite rejection)",
      text_it: "Questo numero non accetta chiamate non sollecitate. " \
               "Per assistenza, scrivere via email all'indirizzo del titolare. Arrivederci.",
      text_en: "This number does not accept unsolicited calls. " \
               "If you need assistance, please contact us by email. Goodbye."
    },
    {
      slug:    "troll_intro",
      label:   "Troll intro",
      text_it: "Buongiorno. La sua chiamata è importante per noi. " \
               "La preghiamo di rimanere in linea.",
      text_en: "Good day. Your call is important to us. Please stay on the line."
    },
    {
      slug:    "troll_hold_loop",
      label:   "Troll hold loop",
      text_it: "Tutti i nostri operatori sono attualmente impegnati con altre chiamate. " \
               "Stiamo lavorando per servirla al più presto. Grazie per la sua pazienza. " \
               "La preghiamo di non riagganciare, la sua chiamata sarà evasa appena possibile.",
      text_en: "All our operators are currently busy with other calls. " \
               "We are working to serve you as soon as possible. Thank you for your patience. " \
               "Please do not hang up, your call will be answered shortly."
    },
    {
      slug:    "troll_voice_menu",
      label:   "Troll voice menu",
      text_it: "Per parlare con un nostro operatore, prema uno. " \
               "Per il servizio clienti, prema due. " \
               "Per altre opzioni, prema tre. " \
               "Per ripetere il menu, prema cancelletto.",
      text_en: "To speak to an operator, press one. " \
               "For customer service, press two. " \
               "For other options, press three. " \
               "To repeat this menu, press hash."
    },
    {
      slug:    "troll_apology",
      label:   "Troll apology",
      text_it: "Ci scusiamo per l'attesa prolungata. " \
               "Il nostro centralino sta riscontrando un volume insolito di chiamate. " \
               "La ringraziamo per la sua cortese pazienza.",
      text_en: "We apologize for the extended wait. " \
               "Our switchboard is experiencing an unusual call volume. " \
               "Thank you for your patience."
    },
    {
      slug:    "troll_disclose",
      label:   "Troll disclose",
      text_it: "La informiamo che questa chiamata è stata identificata come spam " \
               "e archiviata. Arrivederci.",
      text_en: "Please be advised that this call has been identified as spam " \
               "and recorded. Goodbye."
    }
  ].freeze

  def up
    new_slugs = PHRASES.map { |p| p[:slug] }

    # Pre-flight: if a tenant already authored a phrase with one of the
    # soon-to-be-reserved slugs, surface it now rather than silently
    # shadowing it with the system row. (The Phrase validator blocks
    # NEW user phrases on these slugs, but pre-existing rows are exempt.)
    collisions = Phrase.where.not(tenant_id: nil).where(slug: new_slugs).pluck(:tenant_id, :slug)
    if collisions.any?
      raise "user-authored phrases collide with new reserved slugs: " \
            "#{collisions.map { |t, s| "tenant=#{t} slug=#{s}" }.join(', ')}"
    end

    now = Time.current
    rows = PHRASES.reject { |p| Phrase.where(tenant_id: nil, slug: p[:slug]).exists? }.map do |p|
      {
        tenant_id:        nil,
        slug:             p[:slug],
        label:            p[:label],
        kind:             "system_#{p[:slug]}",
        text_it:          p[:text_it],
        text_en:          p[:text_en],
        time_of_day:      "any",
        day_of_week:      "any",
        render_status:    "pending",
        last_rendered_at: nil,
        created_at:       now,
        updated_at:       now
      }
    end
    Phrase.insert_all(rows) if rows.any?

    # Explicitly enqueue render. `insert_all` bypasses `after_commit`,
    # so without this the rows would sit `pending` forever.
    Phrase.where(tenant_id: nil, slug: new_slugs).find_each do |phrase|
      PhraseRenderJob.perform_later(phrase.id)
    end
  end

  def down
    Phrase.where(tenant_id: nil, slug: PHRASES.map { |p| p[:slug] }).destroy_all
  end
end
