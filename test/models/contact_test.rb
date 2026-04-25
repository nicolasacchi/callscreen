require "test_helper"

class ContactTest < ActiveSupport::TestCase
  test "phone is required" do
    c = Contact.new(phone: nil)
    assert_not c.valid?
  end

  test "phone is unique" do
    Contact.create!(phone: "+393335555555")
    dup = Contact.new(phone: "+393335555555")
    assert_not dup.valid?
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
end
