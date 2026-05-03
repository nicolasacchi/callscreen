require "test_helper"

class GreetingCatalogTest < ActiveSupport::TestCase
  test "has exactly 10 variants" do
    assert_equal 10, GreetingCatalog::VARIANTS.size
  end

  test "all slugs are unique" do
    slugs = GreetingCatalog::VARIANTS.map(&:slug)
    assert_equal slugs.size, slugs.uniq.size
  end

  test "every variant has a non-empty label and Italian + English text" do
    GreetingCatalog::VARIANTS.each do |v|
      assert v.slug.present?, "slug missing"
      assert v.label.present?, "label missing for #{v.slug}"
      it_text = v.text("it")
      en_text = v.text("en")
      assert it_text.present?, "Italian text missing for #{v.slug}"
      assert en_text.present?, "English text missing for #{v.slug}"
      assert it_text.length.between?(20, 1000), "Italian text length out of bounds for #{v.slug}"
      assert en_text.length.between?(15, 1000), "English text length out of bounds for #{v.slug}"
    end
  end

  test "no variant text mentions the email (TTS-unfriendly) in any language" do
    GreetingCatalog::VARIANTS.each do |v|
      [ "it", "en" ].each do |lang|
        text = v.text(lang).downcase
        assert_not_includes text, "torreblu",
                            "variant #{v.slug} (#{lang}) must not mention the email"
        assert_not_includes text, "@", "variant #{v.slug} (#{lang}) must not contain literal @"
        assert_not_includes text, "chiocciola",
                            "variant #{v.slug} (it) must not contain phonetic @"
      end
    end
  end

  test "voices and tones are descriptive labels" do
    GreetingCatalog::VOICES.each do |slug, label|
      assert label.match?(/\A[A-Z]/), "voice label should start with a capital letter for slug #{slug}"
      assert_not_includes label.downcase, "sara"
      assert_not_includes label.downcase, "nicola"
    end
    GreetingCatalog::TONES.each do |_slug, info|
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

  test "text_for returns the text in the requested language with fallback to Italian" do
    assert GreetingCatalog.text_for("informal_tu", language: "it").include?("Ciao")
    assert GreetingCatalog.text_for("informal_tu", language: "en").include?("Hi")
    # Default language is Italian
    assert GreetingCatalog.text_for("informal_tu").include?("Ciao")
    # Non-existent slug → nil
    assert_nil GreetingCatalog.text_for("nonexistent")
    # Unknown language falls back to Italian
    assert GreetingCatalog.text_for("informal_tu", language: "fr").include?("Ciao")
  end

  test "text_for works for SYSTEM_PHRASES too" do
    assert_equal "Arrivederci.", GreetingCatalog.text_for("goodbye_short", language: "it")
    assert_equal "Goodbye.",     GreetingCatalog.text_for("goodbye_short", language: "en")
  end

  test "default greeting_variant in Setting::DEFAULTS exists in the catalog" do
    assert GreetingCatalog::SLUGS.include?(Setting::DEFAULTS["greeting_variant"])
  end

  test "SYSTEM_PHRASES has at least the clarify phrase in both languages" do
    assert GreetingCatalog::SYSTEM_PHRASES.key?("clarify")
    assert GreetingCatalog::SYSTEM_PHRASES["clarify"]["it"].include?("non ho capito")
    assert GreetingCatalog::SYSTEM_PHRASES["clarify"]["en"].downcase.include?("didn't catch")
  end

  test "ALL_SLUGS combines variants and system phrases" do
    assert_includes GreetingCatalog::ALL_SLUGS, "informal_tu"
    assert_includes GreetingCatalog::ALL_SLUGS, "clarify"
    assert_equal GreetingCatalog::SLUGS.size + GreetingCatalog::SYSTEM_PHRASES.size,
                 GreetingCatalog::ALL_SLUGS.size
  end

  test "language_for_number maps +39 → it and everything else → en" do
    assert_equal "it", GreetingCatalog.language_for_number("+393990000001")
    assert_equal "it", GreetingCatalog.language_for_number("+39059")
    assert_equal "en", GreetingCatalog.language_for_number("+14155551234")
    assert_equal "en", GreetingCatalog.language_for_number("+447700900123")
    assert_equal "en", GreetingCatalog.language_for_number("")
    assert_equal "en", GreetingCatalog.language_for_number(nil)
  end

  test "voice_for_language swaps Italian voice to English equivalent and vice versa" do
    assert_equal "if_sara",    GreetingCatalog.voice_for_language("if_sara",    "it")
    assert_equal "af_heart",   GreetingCatalog.voice_for_language("if_sara",    "en")
    assert_equal "im_nicola",  GreetingCatalog.voice_for_language("im_nicola",  "it")
    assert_equal "am_michael", GreetingCatalog.voice_for_language("im_nicola",  "en")
    assert_equal "if_sara",    GreetingCatalog.voice_for_language("af_heart",   "it")
    assert_equal "am_michael", GreetingCatalog.voice_for_language("am_michael", "en")
    # Unknown voices pass through unchanged
    assert_equal "custom_voice", GreetingCatalog.voice_for_language("custom_voice", "en")
  end

  test "voice_for_language maps Telnyx fallback voices (alice, man, woman) to Kokoro voices" do
    assert_equal "if_sara",    GreetingCatalog.voice_for_language("alice", "it")
    assert_equal "af_heart",   GreetingCatalog.voice_for_language("alice", "en")
    assert_equal "im_nicola",  GreetingCatalog.voice_for_language("man",   "it")
    assert_equal "am_michael", GreetingCatalog.voice_for_language("man",   "en")
  end
end
