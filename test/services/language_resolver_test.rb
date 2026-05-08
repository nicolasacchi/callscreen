require "test_helper"

class LanguageResolverTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @tenant.update!(auto_detect_language: true)
  end

  def make_call(from_number:, contact: nil)
    Call.new(tenant: @tenant, from_number: from_number, contact: contact)
  end

  test "auto-detects italian from +39 number" do
    c = make_call(from_number: "+393331112222")
    assert_equal "it", LanguageResolver.for(c)
  end

  test "auto-detects english from non-+39 number" do
    c = make_call(from_number: "+447700900000")
    assert_equal "en", LanguageResolver.for(c)
  end

  test "contact.language overrides auto-detect" do
    contact = @tenant.contacts.create!(phone: "+447700900000", language: "it")
    c = make_call(from_number: contact.phone, contact: contact)
    assert_equal "it", LanguageResolver.for(c)
  end

  test "contact.language=nil falls through to auto-detect" do
    contact = @tenant.contacts.create!(phone: "+393331112222", language: nil)
    c = make_call(from_number: contact.phone, contact: contact)
    assert_equal "it", LanguageResolver.for(c)
  end

  test "auto_detect_language=false uses tenant.greeting_language prefix" do
    @tenant.update!(auto_detect_language: false, greeting_language: "en-US")
    c = make_call(from_number: "+393331112222")
    assert_equal "en", LanguageResolver.for(c)
  end

  test "from_e164 maps +39 to it, anything else to en" do
    assert_equal "it", LanguageResolver.from_e164("+393331112222")
    assert_equal "en", LanguageResolver.from_e164("+447700900000")
    assert_equal "en", LanguageResolver.from_e164("anonymous")
  end

  test "tolerates nil call" do
    assert_equal "it", LanguageResolver.for(nil)
  end
end
