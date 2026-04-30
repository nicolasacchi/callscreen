require "test_helper"

class NotifyJobTest < ActiveJob::TestCase
  setup do
    @ntfy_url = ENV["NTFY_URL"]
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")
  end

  test "spam call sends low-priority spam notification" do
    call = calls(:spam_completed)
    call.update!(notified_at: nil)

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s.include?("Spam")
    end
    assert_not_nil call.reload.notified_at
  end

  test "legit call sends high-priority notification" do
    call = calls(:legit_completed)
    call.update!(notified_at: nil, status: :legit)

    NotifyJob.new.perform(call.id)

    assert_requested :post, @ntfy_url, times: 1 do |req|
      req.headers["Title"].to_s.include?(call.from_number) &&
        req.headers["Priority"].to_s == "high"
    end
  end

  test "is idempotent: skips when already notified" do
    call = calls(:spam_completed)
    call.update!(notified_at: 5.minutes.ago)

    NotifyJob.new.perform(call.id)

    assert_not_requested :post, @ntfy_url
  end
end
