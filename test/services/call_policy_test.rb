require "test_helper"

class CallPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant  = tenants(:default)
    @tenant.update!(max_calls_per_caller_per_day: 10)
    @contact = @tenant.contacts.create!(phone: "+393331110000")
    @miss    = RailsdavContactsClient::MISS
  end

  def decide(external: @miss, from: @contact.phone)
    CallPolicy.decide(contact: @contact, tenant: @tenant, external: external, from: from)
  end

  def railsdav(**attrs)
    RailsdavContactsClient::Result.new(
      { matched?: false, name: nil, policy: nil, addressbook: nil,
        spam_global: false, spam_metadata: {} }.merge(attrs)
    )
  end

  test "default disposition is answer" do
    assert decide.answer?
  end

  test "blacklist → silent spam with no push" do
    @contact.update!(blacklisted: true)
    d = decide
    assert d.spam?
    assert_equal "blacklist", d.source
    assert_equal false, d.notify
  end

  test "whitelist → allow" do
    @contact.update!(whitelisted: true)
    assert decide.allow?
  end

  test "railsdav block → spam, railsdav allow → allow" do
    assert decide(external: railsdav(matched?: true, policy: "block", addressbook: "Bad")).spam?
    assert decide(external: railsdav(matched?: true, policy: "allow")).allow?
  end

  test "global spam DB hit → spam, but local whitelist overrides it" do
    spammy = railsdav(spam_global: true, spam_metadata: { "source" => "feed", "report_count" => 9 })
    d = decide(external: spammy)
    assert d.spam?
    assert_equal "spam_db_global", d.source
    assert_includes d.reason, "Global spam DB"

    @contact.update!(whitelisted: true)
    assert decide(external: spammy).allow?, "operator whitelist must win over the global list"
  end

  test "rate limit → force-silent spam; whitelisted caller is exempt" do
    11.times do |i|
      @tenant.calls.create!(call_sid: "rl-#{i}", from_number: @contact.phone, contact: @contact, status: :screening)
    end
    d = decide
    assert d.spam?
    assert_equal "rate_limit", d.source
    assert d.force_silent

    @contact.update!(whitelisted: true)
    assert decide.allow?
  end

  test "tenant block rule → force-silent spam carrying the matched rule" do
    rule = @tenant.rules.create!(rule_type: :prefix, action: :block, value: @contact.phone, active: true)
    d = decide
    assert d.spam?
    assert_equal "rule", d.source
    assert d.force_silent
    assert_equal rule, d.rule
  end
end
