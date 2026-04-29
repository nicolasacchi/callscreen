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
      assert_includes v.text, "example",
                      "variant #{v.slug} should mention the email"
    end
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
end
