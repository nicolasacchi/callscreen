require "test_helper"

class AutoBlacklistPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @tenant.update!(auto_blacklist_threshold: 3, auto_blacklist_window_days: 7)
    @contact = @tenant.contacts.create!(phone: "+393331110000")
    @call = @tenant.calls.create!(call_sid: "ab-call", from_number: @contact.phone,
                                  status: :spam, contact: @contact)
  end

  def seed_spam(n)
    n.times { |i| @tenant.calls.create!(call_sid: "ab-#{i}", from_number: @contact.phone, status: :spam, contact: @contact) }
  end

  test "does not blacklist below the threshold" do
    seed_spam(1) # + the setup's @call = 2 spam, below threshold 3
    refute AutoBlacklistPolicy.decide(@call).blacklist?
  end

  test "blacklists at the threshold and reports the metadata" do
    seed_spam(2) # + the setup's @call = 3 spam, at threshold 3
    d = AutoBlacklistPolicy.decide(@call)
    assert d.blacklist?
    assert_operator d.count, :>=, 3
    assert_equal 7, d.window_days
    assert_equal 3, d.threshold
  end

  test "nil threshold disables auto-blacklist" do
    @tenant.update!(auto_blacklist_threshold: nil)
    seed_spam(10)
    refute AutoBlacklistPolicy.decide(@call).blacklist?
  end

  test "never blacklists a whitelisted contact" do
    @contact.update!(whitelisted: true)
    seed_spam(10)
    refute AutoBlacklistPolicy.decide(@call).blacklist?
  end
end
