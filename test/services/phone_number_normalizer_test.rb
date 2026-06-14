require "test_helper"

class PhoneNumberNormalizerTest < ActiveSupport::TestCase
  test "returns blank input unchanged" do
    assert_nil PhoneNumberNormalizer.normalize(nil)
    assert_equal "", PhoneNumberNormalizer.normalize("")
  end

  test "normalizes Italian numbers to E.164" do
    assert_equal "+393331234567", PhoneNumberNormalizer.normalize("3331234567")
  end

  test "preserves already-E.164 international numbers" do
    assert_equal "+14155551234", PhoneNumberNormalizer.normalize("+14155551234")
  end

  test "returns stripped original for malformed input" do
    assert_equal "abc", PhoneNumberNormalizer.normalize("  abc  ")
  end

  test "e164 returns E.164 for a valid number and nil for an invalid one" do
    assert_equal "+393331234567", PhoneNumberNormalizer.e164("3331234567")
    assert_equal "+393331234567", PhoneNumberNormalizer.e164("+393331234567")
    assert_nil PhoneNumberNormalizer.e164("anonymous")
    assert_nil PhoneNumberNormalizer.e164(nil)
    assert_nil PhoneNumberNormalizer.e164("")
  end

  test "default_country honors PHONE_DEFAULT_COUNTRY (single source of truth with railsdav)" do
    prev = ENV["PHONE_DEFAULT_COUNTRY"]
    ENV["PHONE_DEFAULT_COUNTRY"] = "GB"
    assert_equal "GB", PhoneNumberNormalizer.default_country
  ensure
    prev ? (ENV["PHONE_DEFAULT_COUNTRY"] = prev) : ENV.delete("PHONE_DEFAULT_COUNTRY")
  end
end
