require "test_helper"

class NotifyJobTest < ActiveJob::TestCase
  setup do
    @ntfy_url = ENV["NTFY_URL"]
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")
  end

  test "spam call sends low-priority spam notification using contact name" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil)
    # spammer fixture has no name → fallback to from_number in the title
    assert_nil call.contact.name

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s.include?("Spam") &&
        req.headers["Title"].to_s.include?(call.from_number) &&
        req.body.to_s.include?("Da: #{call.from_number}")
    end
    assert_not_nil call.reload.notified_at
  end

  test "spam message renders the confidence percentage" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil,
                 ai_classification: { "classification" => "spam", "confidence" => 0.9, "reason" => "x" })
    NotifyJob.new.perform(call.id)
    assert_requested :post, @ntfy_url do |req|
      req.body.to_s.include?("Confidenza: 90%")
    end
  end

  test "legit message renders the confidence suffix" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil, status: :legit,
                 ai_classification: { "classification" => "legit", "confidence" => 0.75, "reason" => "x" })
    NotifyJob.new.perform(call.id)
    assert_requested :post, @ntfy_url do |req|
      req.body.to_s.include?("(75%)")
    end
  end

  test "includes the ai_summary TL;DR line when present (P2-3)" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil,
                 ai_classification: { "classification" => "spam", "confidence" => 0.9,
                                      "reason" => "robocall", "summary" => "Telemarketing energia." })
    NotifyJob.new.perform(call.id)
    assert_requested :post, @ntfy_url do |req|
      req.body.to_s.include?("Telemarketing energia.")
    end
  end

  test "spam notification uses contact.name in title when present" do
    call = calls(:spam_completed)
    call.contact.update!(name: "Mario Spam")
    call.update!(notified_at: nil)

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s == "📵 Spam: Mario Spam" &&
        req.body.to_s.include?("Da: #{call.from_number}")
    end
  end

  test "legit call sends high-priority notification using contact name" do
    call = calls(:legit_completed)
    call.update!(notified_at: nil, status: :legit)
    assert_equal "Mario Rossi", call.contact.name

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s == "📞 Da Mario Rossi" &&
        req.headers["Priority"].to_s == "high" &&
        req.body.to_s.include?("Da: #{call.from_number}")
    end
  end

  test "unknown status sends question-tagged notification" do
    call = calls(:legit_completed)
    call.update!(notified_at: nil, status: :unknown)

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s.start_with?("❓ Sconosciuto:") &&
        req.body.to_s.include?("Il chiamante non ha detto nulla.") &&
        req.body.to_s.include?("Da: #{call.from_number}")
    end
  end

  test "is idempotent: skips when already notified" do
    call = calls(:spam_completed)
    call.update!(notified_at: 5.minutes.ago)

    NotifyJob.new.perform(call.id)

    assert_not_requested :post, @ntfy_url
  end

  test "duplicate enqueues push exactly once (atomic notified_at claim)" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil)

    NotifyJob.new.perform(call.id)
    NotifyJob.new.perform(call.id)

    # Second run loses the claim (notified_at already set) and sends nothing.
    assert_requested :post, @ntfy_url, times: 1
  end

  test "uncertain status is triaged, not shown as a clean high-priority legit call" do
    call = calls(:legit_completed)
    call.update!(notified_at: nil, status: :uncertain,
                 ai_classification: { "classification" => "spam", "confidence" => 0.4, "reason" => "forse" })

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s.start_with?("⚠️ Incerto:") &&
        req.headers["Priority"].to_s == "default" &&
        req.headers["Tags"].to_s.include?("question") &&
        req.body.to_s.include?("possibile spam")
    end
  end

  test "a failed push releases the notified_at claim and raises so it retries" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil)
    stub_request(:post, @ntfy_url).to_return(status: 503, body: "boom")

    assert_raises(NtfyNotifier::DeliveryError) { NotifyJob.new.perform(call.id) }
    assert_nil call.reload.notified_at, "claim must be released so the retry re-attempts"
  end
end
