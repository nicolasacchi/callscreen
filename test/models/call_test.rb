require "test_helper"

class CallTest < ActiveSupport::TestCase
  test "total_cost_usd sums telnyx + moonshot when both set" do
    call = Call.new(telnyx_cost_usd: 0.0014, moonshot_cost_usd: 0.0002)
    assert_in_delta 0.0016, call.total_cost_usd, 1e-9
  end

  test "total_cost_usd treats nil as 0" do
    assert_equal 0.0, Call.new.total_cost_usd
    assert_equal 0.5, Call.new(telnyx_cost_usd: 0.5).total_cost_usd
    assert_equal 0.5, Call.new(moonshot_cost_usd: 0.5).total_cost_usd
  end

  test "llm_classified? is true only for ai_classification_source=llm" do
    assert_not Call.new.llm_classified?
    assert_not Call.new(ai_classification_source: "rate_limit").llm_classified?
    assert_not Call.new(ai_classification_source: "keyword").llm_classified?
    assert     Call.new(ai_classification_source: "llm").llm_classified?
  end
end
