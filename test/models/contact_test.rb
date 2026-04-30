require "test_helper"

class ContactTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @other  = tenants(:other)
  end

  test "phone is required" do
    c = Contact.new(phone: nil, tenant: @tenant)
    assert_not c.valid?
  end

  test "tenant is required" do
    c = Contact.new(phone: "+393335555555", tenant: nil)
    assert_not c.valid?
    assert_includes c.errors.full_messages.join(" "), "Tenant"
  end

  test "phone is unique within a tenant" do
    @tenant.contacts.create!(phone: "+393335555555")
    dup = @tenant.contacts.new(phone: "+393335555555")
    assert_not dup.valid?
  end

  test "same phone is allowed across different tenants" do
    @tenant.contacts.create!(phone: "+393336666666")
    cross = @other.contacts.new(phone: "+393336666666")
    assert cross.valid?, "phone uniqueness must be scoped per-tenant"
  end

  test "display_name returns name when present, phone otherwise" do
    assert_equal "Mario Rossi", contacts(:regular).display_name
    assert_equal "+393331111111", contacts(:unknown).display_name
  end

  test "scopes return correct subsets" do
    assert_includes Contact.whitelisted, contacts(:vip)
    assert_includes Contact.blacklisted, contacts(:spammer)
    assert_not_includes Contact.whitelisted, contacts(:spammer)
  end

  test "recent_calls_count counts calls within the window only" do
    contact = @tenant.contacts.create!(phone: "+393998877665")
    @tenant.calls.create!(call_sid: "rcc-old", from_number: contact.phone, contact: contact, status: :completed, created_at: 2.days.ago)
    @tenant.calls.create!(call_sid: "rcc-new", from_number: contact.phone, contact: contact, status: :completed, created_at: 1.hour.ago)
    assert_equal 1, contact.recent_calls_count(within: 24.hours)
    assert_equal 2, contact.recent_calls_count(within: 7.days)
  end

  test "recent_spam_count filters by status: spam" do
    contact = @tenant.contacts.create!(phone: "+393997766554")
    @tenant.calls.create!(call_sid: "rsc-spam",  from_number: contact.phone, contact: contact, status: :spam,  created_at: 2.days.ago)
    @tenant.calls.create!(call_sid: "rsc-legit", from_number: contact.phone, contact: contact, status: :legit, created_at: 1.day.ago)
    @tenant.calls.create!(call_sid: "rsc-old",   from_number: contact.phone, contact: contact, status: :spam,  created_at: 30.days.ago)
    assert_equal 1, contact.recent_spam_count(within: 7.days)
  end
end
