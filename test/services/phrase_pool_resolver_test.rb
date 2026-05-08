require "test_helper"

class PhrasePoolResolverTest < ActiveSupport::TestCase
  setup do
    @tenant  = tenants(:default)
    @tenant.update!(auto_detect_language: true)
    @contact = @tenant.contacts.create!(phone: "+393331112222")
    @call    = Call.new(tenant: @tenant, from_number: @contact.phone, contact: @contact)

    # `informal_tu` is the fixture-loaded fallback (tenant.greeting_variant=informal_tu).
    @fallback = phrases(:informal_tu)
  end

  def at(time_str)
    Time.zone.parse("2026-05-05 #{time_str} +0200")
  end

  def author(slug:, tod: "any", text_it: "ciao", text_en: "hi", tenant: @tenant)
    Phrase.create!(
      tenant:           tenant,
      slug:             slug,
      label:            slug.tr("_", " "),
      kind:             "user",
      text_it:          text_it,
      text_en:          text_en,
      time_of_day:      tod,
      render_status:    "rendered",
      last_rendered_at: Time.current
    )
  end

  test "tier 7: returns the static greeting_variant phrase when no other layer fires" do
    phrase = PhrasePoolResolver.new(call: @call, now: at("14:00")).resolve!
    assert_equal @fallback.id, phrase.id
  end

  test "tier 1: contact direct pool TOD-matched wins" do
    p_morning = author(slug: "buongiorno", tod: "morning")
    @contact.phrases << p_morning
    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_equal p_morning.id, chosen.id
  end

  test "tier 4: when TOD-matched contact pool is empty, falls back to contact any-TOD" do
    p_any = author(slug: "any_one", tod: "any")
    @contact.phrases << p_any
    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_equal p_any.id, chosen.id
  end

  test "tier 3: tag-matched is layer 2; tenant_default tod-matched is layer 3" do
    tag = Tag.create!(tenant: @tenant, name: "family")
    @contact.tags << tag
    # Tag-matched, morning
    p_tagged = author(slug: "tag_morning", tod: "morning")
    p_tagged.tags << tag
    # Tenant default, morning
    p_default = author(slug: "default_morning", tod: "morning")
    @tenant.tenant_phrases.create!(phrase: p_default, position: 0)
    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_equal p_tagged.id, chosen.id   # tag wins over tenant default
  end

  test "tier 6: tenant default any-TOD" do
    p_any = author(slug: "tenant_any", tod: "any")
    @tenant.tenant_phrases.create!(phrase: p_any, position: 0)
    chosen = PhrasePoolResolver.new(call: @call, now: at("23:00")).resolve!
    assert_equal p_any.id, chosen.id
  end

  test "pending phrase invisible: skips ahead to next layer" do
    p_pending = author(slug: "pending_morning", tod: "morning")
    p_pending.update_columns(render_status: "pending")
    @contact.phrases << p_pending

    # No other contact phrase, no tag, no tenant default.
    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_equal @fallback.id, chosen.id
  end

  test "wrong language phrase invisible (Italian-only phrase, English caller)" do
    @contact.update!(language: "en", phone: "+447700900000")
    @call.contact     = @contact
    @call.from_number = @contact.phone

    p_italian_only = author(slug: "italian_only", text_it: "ciao", text_en: nil)
    @contact.phrases << p_italian_only

    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    # Falls back through chain → fallback informal_tu (which has both langs)
    assert_equal @fallback.id, chosen.id
  end

  test "cursor advance: per-contact independent" do
    a = author(slug: "morning_a", tod: "morning")
    b = author(slug: "morning_b", tod: "morning")
    c = author(slug: "morning_c", tod: "morning")
    @contact.phrases << [ a, b, c ]

    slugs = 4.times.map do
      PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!.slug
    end
    assert_equal [ "morning_a", "morning_b", "morning_c", "morning_a" ], slugs
    assert_equal 4, @contact.reload.phrase_rotation_index
  end

  test "cursor advance: tenant cursor for default-pool layer (no contact)" do
    a = author(slug: "default_one", tod: "any")
    b = author(slug: "default_two", tod: "any")
    @tenant.tenant_phrases.create!(phrase: a, position: 0)
    @tenant.tenant_phrases.create!(phrase: b, position: 1)
    call_no_contact = Call.new(tenant: @tenant, from_number: "+393339999999", contact: nil)

    slugs = 3.times.map do
      PhrasePoolResolver.new(call: call_no_contact, now: at("23:00")).resolve!.slug
    end
    assert_equal [ "default_one", "default_two", "default_one" ], slugs
    assert_equal 3, @tenant.reload.phrase_rotation_index
  end

  test "cursor advance: empty layer does NOT advance contact cursor" do
    # Mario calls at 03:00 (night). His contact pool has only a morning
    # phrase. So we fall to tier 6 (tenant default any). The contact
    # cursor must NOT advance, so when Mario calls again at 08:00
    # (morning), he starts at the same cursor.
    p_morning = author(slug: "morning_only", tod: "morning")
    p_default = author(slug: "default_any",  tod: "any")
    @contact.phrases << p_morning
    @tenant.tenant_phrases.create!(phrase: p_default, position: 0)

    PhrasePoolResolver.new(call: @call, now: at("03:00")).resolve!
    assert_equal 0, @contact.reload.phrase_rotation_index, "contact cursor should not have advanced"

    # Add a second morning phrase so cursor matters
    p_morning_b = author(slug: "morning_only_b", tod: "morning")
    @contact.phrases << p_morning_b

    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_equal "morning_only", chosen.slug, "cursor should still be at index 0 for morning pool"
  end

  test "tag union: phrases reachable via any of contact's tags" do
    tag_a = Tag.create!(tenant: @tenant, name: "family")
    tag_b = Tag.create!(tenant: @tenant, name: "work")
    @contact.tags << [ tag_a, tag_b ]

    p_a = author(slug: "fam_morning", tod: "morning")
    p_a.tags << tag_a
    p_b = author(slug: "work_morning", tod: "morning")
    p_b.tags << tag_b

    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    assert_includes [ p_a.id, p_b.id ], chosen.id
  end

  test "different tenant's phrases are not visible" do
    other_tenant = tenants(:other)
    other_tenant.update!(greeting_variant: "informal_tu")
    foreign = author(slug: "foreign_phrase", tenant: other_tenant)

    chosen = PhrasePoolResolver.new(call: @call, now: at("08:00")).resolve!
    refute_equal "foreign_phrase", chosen.slug
  end

  test "day_of_week filter: weekend phrase invisible on a Tuesday" do
    p_weekend = author(slug: "weekend_brunch", tod: "morning")
    p_weekend.update!(day_of_week: "weekend")
    @contact.phrases << p_weekend

    tuesday_morning = Time.zone.parse("2026-05-05 08:00 +0200")
    chosen = PhrasePoolResolver.new(call: @call, now: tuesday_morning).resolve!
    refute_equal "weekend_brunch", chosen.slug
  end

  test "day_of_week filter: weekend phrase plays on Saturday" do
    p_weekend = author(slug: "weekend_brunch_2", tod: "morning")
    p_weekend.update!(day_of_week: "weekend")
    @contact.phrases << p_weekend

    saturday_morning = Time.zone.parse("2026-05-09 08:00 +0200")
    chosen = PhrasePoolResolver.new(call: @call, now: saturday_morning).resolve!
    assert_equal "weekend_brunch_2", chosen.slug
  end

  test "day_of_week filter: specific day filters correctly" do
    p_friday = author(slug: "friday_only", tod: "afternoon")
    p_friday.update!(day_of_week: "friday")
    @contact.phrases << p_friday

    friday_pm   = Time.zone.parse("2026-05-08 14:00 +0200")
    thursday_pm = Time.zone.parse("2026-05-07 14:00 +0200")
    assert_equal "friday_only",
                 PhrasePoolResolver.new(call: @call, now: friday_pm).resolve!.slug
    refute_equal "friday_only",
                 PhrasePoolResolver.new(call: @call, now: thursday_pm).resolve!.slug
  end

  test "TOD respects tenant time zone" do
    @tenant.update!(time_zone: "America/Los_Angeles")
    p_morning = author(slug: "morning_la", tod: "morning")
    @contact.phrases << p_morning
    # 16:00 UTC = 09:00 in LA = morning slot
    chosen = PhrasePoolResolver.new(call: @call, now: Time.utc(2026, 5, 5, 16, 0)).resolve!
    assert_equal p_morning.id, chosen.id
  end
end
