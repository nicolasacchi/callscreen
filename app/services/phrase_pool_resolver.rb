# Resolves the next phrase to play for a given call. Walks a 7-tier
# fallback chain (per the design plan); only the *owning* layer
# advances its cursor — empty layers don't shift any cursor, fixing
# the "Mario calls at 03:00 and his afternoon rotation skips a
# phrase" rotation bug.
#
# Tiers:
#   1. Direct contact pool, TOD-matched              [contact cursor]
#   2. Tag-matched pool, TOD-matched                 [contact cursor]
#   3. Tenant default pool, TOD-matched              [tenant cursor]
#   4. Direct contact pool, time_of_day=any          [contact cursor]
#   5. Tag-matched pool, time_of_day=any             [contact cursor]
#   6. Tenant default pool, time_of_day=any          [tenant cursor]
#   7. Phrase.find_by(slug: tenant.greeting_variant) [no cursor advance]
#
# Every tier is gated on `Phrase.rendered.with_text(lang)`. Pending /
# failed phrases are invisible. The data-migration seed guarantees
# tier 7 has a row, so #resolve! never returns nil.
class PhrasePoolResolver
  def initialize(call:, now: Time.current)
    @call    = call
    @tenant  = call.tenant
    @contact = call.contact
    @lang    = LanguageResolver.for(call)
    zone     = (@tenant&.time_zone.presence || "Europe/Rome")
    zoned    = now.in_time_zone(zone)
    @tod     = TimeOfDaySlot.current(@tenant, now)
    @day     = DayOfWeekSlot.current(zoned)
  end

  def resolve!
    %i[
      contact_direct_tod
      contact_tag_tod
      tenant_default_tod
      contact_direct_any
      contact_tag_any
      tenant_default_any
    ].each do |tier|
      candidates = send(tier)
      Rails.logger.info("phrase_resolver_debug: tier=#{tier} count=#{candidates.size} contact_id=#{@contact&.id} phrase_ids=#{@contact&.phrase_ids.inspect}") if ENV["PHRASE_RESOLVER_DEBUG"] == "1"
      next if candidates.empty?
      phrase = pick_with_cursor!(candidates, cursor_owner_for(tier))
      return phrase if phrase
    end

    fallback_to_static_greeting_variant
  end

  private

  attr_reader :call, :tenant, :contact, :lang, :tod, :day

  def base_scope
    # Day-of-week is a hard AND filter applied to every layer — a
    # phrase whose day_of_week doesn't include the current day is
    # ignored regardless of TOD or pool. day_of_week='any' makes a
    # phrase day-agnostic (the default for shared system phrases).
    Phrase.rendered.with_text(lang).visible_to(tenant).matching_day(day)
  end

  def contact_direct_tod
    return [] unless contact
    base_scope.joins(:contact_phrases)
              .where(contact_phrases: { contact_id: contact.id })
              .where(time_of_day: [ tod.to_s, "any" ])
              .where.not(time_of_day: "any") # tier 1 is TOD-matched only
              .order(:id)
              .to_a
  end

  def contact_direct_any
    return [] unless contact
    base_scope.joins(:contact_phrases)
              .where(contact_phrases: { contact_id: contact.id })
              .where(time_of_day: "any")
              .order(:id)
              .to_a
  end

  def contact_tag_tod
    return [] unless contact && contact.tags.any?
    tag_ids = contact.tag_ids
    base_scope.joins(:phrase_tags)
              .where(phrase_tags: { tag_id: tag_ids })
              .where.not(time_of_day: "any")
              .where(time_of_day: tod.to_s)
              .distinct
              .order(:id)
              .to_a
  end

  def contact_tag_any
    return [] unless contact && contact.tags.any?
    tag_ids = contact.tag_ids
    base_scope.joins(:phrase_tags)
              .where(phrase_tags: { tag_id: tag_ids })
              .where(time_of_day: "any")
              .distinct
              .order(:id)
              .to_a
  end

  def tenant_default_tod
    return [] unless tenant
    base_scope.joins(:tenant_phrases)
              .where(tenant_phrases: { tenant_id: tenant.id })
              .where(time_of_day: tod.to_s)
              .where.not(time_of_day: "any")
              .order("tenant_phrases.position")
              .to_a
  end

  def tenant_default_any
    return [] unless tenant
    base_scope.joins(:tenant_phrases)
              .where(tenant_phrases: { tenant_id: tenant.id })
              .where(time_of_day: "any")
              .order("tenant_phrases.position")
              .to_a
  end

  def fallback_to_static_greeting_variant
    return nil unless tenant.greeting_variant.present?
    Phrase.visible_to(tenant)
          .with_text(lang)
          .find_by(slug: tenant.greeting_variant) ||
      # Truly last resort: any rendered shared phrase. Guaranteed by seed.
      Phrase.where(tenant_id: nil).rendered.with_text(lang).first
  end

  def cursor_owner_for(tier)
    tier.to_s.start_with?("contact_") ? contact : tenant
  end

  def pick_with_cursor!(candidates, owner)
    return nil if candidates.empty?
    return candidates.first unless owner

    # Both Contact and Tenant name the cursor column phrase_rotation_index.
    cursor_attr = :phrase_rotation_index
    chosen = nil
    owner.with_lock do
      idx = owner.public_send(cursor_attr) || 0
      chosen = candidates[idx % candidates.size]
      next_idx = (idx + 1) % (candidates.size * 1_000)
      owner.update_columns(cursor_attr => next_idx)
    end
    chosen
  end
end
