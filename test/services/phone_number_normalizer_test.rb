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
end
