require "test_helper"

# P2-8: the CHECK constraints must reject invalid data even when the Ruby
# validations are bypassed (raw SQL, seeds, `rails runner`, update_columns).
class DataIntegrityConstraintsTest < ActiveSupport::TestCase
  setup { @tenant = tenants(:default) }

  test "rejects an out-of-range call status (update_columns bypasses validation)" do
    call = @tenant.calls.create!(call_sid: "ic-1", from_number: "+390000000001", status: :spam)
    assert_raises(ActiveRecord::StatementInvalid) { call.update_columns(status: 99) }
  end

  test "rejects an unknown flow_state" do
    call = @tenant.calls.create!(call_sid: "ic-2", from_number: "+390000000002", status: :screening)
    assert_raises(ActiveRecord::StatementInvalid) { call.update_columns(flow_state: "bogus_state") }
  end

  test "rejects spam_sensitivity out of the 0..1 range" do
    assert_raises(ActiveRecord::StatementInvalid) { @tenant.update_columns(spam_sensitivity: 5.0) }
  end

  test "rejects an invalid phrase render_status" do
    phrase = Phrase.create!(tenant: @tenant, slug: "ic_phrase", label: "X", kind: "user", text_it: "x")
    assert_raises(ActiveRecord::StatementInvalid) { phrase.update_columns(render_status: "bogus") }
  end
end
