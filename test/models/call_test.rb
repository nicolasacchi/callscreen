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

  test "spam_evidence_note prefers ai_summary, appends confidence, collapses control chars" do
    call = Call.new(ai_classification: { "summary" => "Telemarketing\r\nenergia", "confidence" => 0.92 })
    assert_equal "Telemarketing energia (conf 92%)", call.spam_evidence_note
  end

  test "spam_evidence_note falls back to reason and is nil without LLM evidence" do
    assert_equal "Robocall", Call.new(ai_classification: { "reason" => "Robocall" }).spam_evidence_note
    assert_nil Call.new.spam_evidence_note
  end

  test "external lookup accessors read the persisted railsdav snapshot" do
    call = Call.new(spam_global: true, external_lookup_meta: {
      "policy" => "screen", "addressbook" => "Pazienti", "contact_id" => 42,
      "spam_metadata" => { "report_count" => 8, "source" => "ntfy_report" }
    })
    assert call.spam_global?
    assert_equal "screen", call.external_policy
    assert_equal "Pazienti", call.external_addressbook
    assert_equal 42, call.external_contact_id
    assert_equal 8, call.spam_global_meta["report_count"]
  end
end
