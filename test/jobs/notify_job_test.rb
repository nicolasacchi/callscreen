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
end
