require "test_helper"

class NtfyNotifierTest < ActiveSupport::TestCase
  setup do
    @url = ENV["NTFY_URL"]
    NtfyNotifier.reset_failure_count!
  end

  test "no-op when NTFY_URL is blank" do
    ENV.delete("NTFY_URL")
    NtfyNotifier.notify(title: "x", message: "y")
    assert_not_requested :post, /./
  ensure
    ENV["NTFY_URL"] = @url
  end

  test "successful POST resets failure counter" do
    NtfyNotifier.consecutive_failures = 5
    stub_request(:post, @url).to_return(status: 200)
    NtfyNotifier.notify(title: "x", message: "y")
    assert_equal 0, NtfyNotifier.consecutive_failures
  end

  test "connection failure increments failure counter" do
    stub_request(:post, @url).to_raise(SocketError.new("connection refused"))
    NtfyNotifier.notify(title: "x", message: "y")
    assert_equal 1, NtfyNotifier.consecutive_failures
  end

  test "warns to logger after WARN_THRESHOLD consecutive failures" do
    stub_request(:post, @url).to_raise(SocketError.new("boom"))

    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      NtfyNotifier::WARN_THRESHOLD.times do
        NtfyNotifier.notify(title: "x", message: "y")
      end
      assert_match(/#{NtfyNotifier::WARN_THRESHOLD} consecutive times/, io.string)
    ensure
      Rails.logger = original
    end
  end

  test "does NOT warn before threshold is reached" do
    stub_request(:post, @url).to_raise(SocketError.new("boom"))

    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      (NtfyNotifier::WARN_THRESHOLD - 1).times do
        NtfyNotifier.notify(title: "x", message: "y")
      end
      assert_no_match(/consecutive times/, io.string)
    ensure
      Rails.logger = original
    end
  end
end
