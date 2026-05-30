require "test_helper"

class PhraseTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "valid: tenant-owned with both languages" do
    p = Phrase.new(tenant: @tenant, slug: "ti_chiamo_dopo_pranzo",
                   label: "Pomeriggio caldo", kind: "user",
                   text_it: "Ciao, ti chiamo dopo pranzo.",
                   text_en: "Hi, I'll call you back after lunch.")
    assert p.valid?, p.errors.full_messages.to_s
  end

  test "requires at least one language" do
    p = Phrase.new(tenant: @tenant, slug: "x", label: "X", kind: "user")
    refute p.valid?
    assert_match(/at least one language/, p.errors.full_messages.first)
  end

  test "slug must match SLUG_FORMAT (no dashes)" do
    p = Phrase.new(tenant: @tenant, slug: "ti-chiamo-dopo", label: "X",
                   kind: "user", text_it: "ciao")
    refute p.valid?
    assert_includes p.errors[:slug].first, "is invalid"
  end

  test "slug uniqueness scoped per tenant_id" do
    Phrase.create!(tenant: @tenant, slug: "my_slug", label: "A", kind: "user", text_it: "a")
    dup = Phrase.new(tenant: @tenant, slug: "my_slug", label: "B", kind: "user", text_it: "b")
    refute dup.valid?
    # Same slug under a different tenant_id is allowed
    other = tenants(:other)
    other_t = Phrase.new(tenant: other, slug: "my_slug", label: "C", kind: "user", text_it: "c")
    assert other_t.valid?, other_t.errors.full_messages.to_s
  end

  test "user phrase cannot use a reserved system slug" do
    p = Phrase.new(tenant: @tenant, slug: "voicemail_prompt",
                   label: "Custom", kind: "user", text_it: "boom")
    refute p.valid?
    assert_includes p.errors[:slug].first, "reserved by the system catalog"
  end

  test "kind/render_status/time_of_day are inclusion-validated" do
    p = phrases(:informal_tu)
    p.kind = "garbage"
    refute p.valid?
    p.kind = "user"
    p.render_status = "exploded"
    refute p.valid?
    p.render_status = "rendered"
    p.time_of_day = "midnight"
    refute p.valid?
  end

  test "rendered scope filters by status" do
    Phrase.create!(tenant: @tenant, slug: "pending_one", label: "p", kind: "user",
                   text_it: "p", render_status: "pending")
    refute_includes Phrase.rendered.pluck(:slug), "pending_one"
    assert_includes Phrase.rendered.pluck(:slug), "informal_tu"
  end

  test "with_text(lang) requires it/en allowlist" do
    assert_raises(ArgumentError) { Phrase.with_text("fr") }
    assert Phrase.with_text("it").any?
    assert Phrase.with_text("en").any?
  end

  test "with_text(lang) excludes phrases missing that language" do
    p = Phrase.create!(tenant: @tenant, slug: "italian_only",
                       label: "ITA", kind: "user", text_it: "ciao", text_en: nil)
    refute_includes Phrase.with_text("en").pluck(:slug), "italian_only"
    assert_includes Phrase.with_text("it").pluck(:slug), "italian_only"
  end

  test "visible_to scope returns shared + own" do
    p = Phrase.create!(tenant: @tenant, slug: "own_only", label: "X", kind: "user", text_it: "x")
    other = tenants(:other)
    visible_to_other = Phrase.visible_to(other).pluck(:slug)
    refute_includes visible_to_other, "own_only"
    assert_includes visible_to_other, "informal_tu"
  end

  test "text(lang) falls back when target language is missing" do
    p = Phrase.create!(tenant: @tenant, slug: "italian_only_2",
                       label: "X", kind: "user", text_it: "ciao")
    assert_equal "ciao", p.text("en")  # falls back to text_it
    assert_equal "ciao", p.text("it")
  end

  test "system? helper" do
    refute phrases(:informal_tu).system?
    assert phrases(:voicemail_prompt).system?
  end

  test "cannot change kind from system to user on persisted row" do
    sys = phrases(:voicemail_prompt)
    sys.kind = "user"
    refute sys.valid?
    assert_includes sys.errors[:kind].first, "cannot change kind"
  end
end
