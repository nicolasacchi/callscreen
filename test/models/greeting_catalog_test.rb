require "test_helper"

class GreetingCatalogTest < ActiveSupport::TestCase
  test "has exactly 10 variants" do
    assert_equal 10, GreetingCatalog::VARIANTS.size
  end

  test "all slugs are unique" do
    slugs = GreetingCatalog::VARIANTS.map(&:slug)
    assert_equal slugs.size, slugs.uniq.size
  end

  test "every variant has a non-empty label and text" do
    GreetingCatalog::VARIANTS.each do |v|
      assert v.slug.present?, "slug missing"
      assert v.label.present?, "label missing for #{v.slug}"
      assert v.text.present?, "text missing for #{v.slug}"
      assert v.text.length.between?(20, 1000), "text length out of bounds for #{v.slug}"
    end
  end

  test "every variant text contains the phonetic email" do
    GreetingCatalog::VARIANTS.each do |v|
      assert_includes v.text, "torreblu",
                      "variant #{v.slug} should mention the email"
    end
  end

  test "voices and tones are descriptive labels" do
    GreetingCatalog::VOICES.each do |slug, label|
      assert label.match?(/\A[A-Z]/), "voice label should start with a capital letter for slug #{slug}"
      assert_not_includes label.downcase, "sara"
      assert_not_includes label.downcase, "nicola"
    end
    GreetingCatalog::TONES.each do |slug, info|
      assert info[:label].present?
      assert info[:speed].is_a?(Numeric)
      assert info[:speed].between?(0.5, 1.5)
    end
  end

  test "default tone in Setting::DEFAULTS exists in the catalog" do
    assert GreetingCatalog::TONE_SLUGS.include?(Setting::DEFAULTS["greeting_tone"])
  end

  test "find returns the variant by slug" do
    assert_equal "informal_tu", GreetingCatalog.find("informal_tu").slug
    assert_nil GreetingCatalog.find("nonexistent")
  end

  test "text_for returns the text or nil" do
    assert GreetingCatalog.text_for("informal_tu").include?("Ciao")
    assert_nil GreetingCatalog.text_for("nonexistent")
  end

  test "default greeting_variant in Setting::DEFAULTS exists in the catalog" do
    assert GreetingCatalog::SLUGS.include?(Setting::DEFAULTS["greeting_variant"])
  end

  test "SYSTEM_PHRASES has at least the clarify phrase" do
    assert GreetingCatalog::SYSTEM_PHRASES.key?("clarify")
    assert GreetingCatalog::SYSTEM_PHRASES["clarify"].include?("non ho capito")
  end

  test "ALL_SLUGS combines variants and system phrases" do
    assert_includes GreetingCatalog::ALL_SLUGS, "informal_tu"
    assert_includes GreetingCatalog::ALL_SLUGS, "clarify"
    assert_equal GreetingCatalog::SLUGS.size + GreetingCatalog::SYSTEM_PHRASES.size,
                 GreetingCatalog::ALL_SLUGS.size
  end
end
