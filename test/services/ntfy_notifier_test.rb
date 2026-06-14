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

  test "tenant ntfy_url 'disabled' suppresses the push even when ENV fallback is set" do
    # The e2e tenant relies on this so test runs never push to the operator's
    # real phone; a regression here would silently spam them (TEST-4).
    NtfyNotifier.notify(title: "x", message: "y", url: "disabled")
    assert_not_requested :post, /./
  end

  test "per-tenant url overrides the ENV fallback" do
    tenant_url = "https://ntfy.example.test/tenant-specific"
    tenant_stub = stub_request(:post, tenant_url).to_return(status: 200)
    NtfyNotifier.notify(title: "x", message: "y", url: tenant_url)
    assert_requested tenant_stub
    assert_not_requested :post, @url # not the ENV default
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

  test "no Actions header when call: not passed" do
    stub_request(:post, @url).to_return(status: 200)
    NtfyNotifier.notify(title: "x", message: "y")
    assert_requested :post, @url do |req|
      !req.headers.key?("Actions")
    end
  end

  test "Actions header has 3 segments (Whitelist / Mark spam / Report globally) when call: is passed" do
    tenant = tenants(:default)
    call = tenant.calls.create!(
      call_sid: "actions-test-1", call_control_id: "actions-test-1",
      from_number: "+393331112222", status: :spam
    )
    stub_request(:post, @url).to_return(status: 200)

    NtfyNotifier.notify(title: "x", message: "y", call: call)

    assert_requested :post, @url do |req|
      h = req.headers["Actions"]
      h.is_a?(String) &&
        h.scan(/;/).size == 2 &&  # 3 actions => 2 separators
        h.include?("Whitelist") &&
        h.include?("Mark spam") &&
        h.include?("Report globally") &&
        h.include?("/ntfy/calls/#{call.id}/whitelist") &&
        h.include?("/ntfy/calls/#{call.id}/report_spam_globally")
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

  # === non-2xx delivery: the prime silent-failure bug ===

  test "non-2xx response is a failure: returns false, logs the code, bumps the counter (no reset)" do
    NtfyNotifier.consecutive_failures = 0
    stub_request(:post, @url).to_return(status: 403, body: "forbidden topic")

    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      result = NtfyNotifier.notify(title: "x", message: "y")
      assert_equal false, result, "a rejected push must report failure"
      assert_equal 1, NtfyNotifier.consecutive_failures, "non-2xx must increment the failure counter"
      assert_match(/403/, io.string)
    ensure
      Rails.logger = original
    end
  end

  test "a 2xx delivery returns true" do
    stub_request(:post, @url).to_return(status: 200)
    assert_equal true, NtfyNotifier.notify(title: "x", message: "y")
  end

  test "a 'disabled'/blank destination returns true (suppressed, not a failure)" do
    assert_equal true, NtfyNotifier.notify(title: "x", message: "y", url: "disabled")
  end

  test "CR/LF in the title is stripped so Net::HTTP can't be crashed or header-injected" do
    stub_request(:post, @url).to_return(status: 200)
    NtfyNotifier.notify(title: "Mario\r\nX-Evil: 1", message: "y")
    assert_requested :post, @url do |req|
      t = req.headers["Title"].to_s
      !t.include?("\n") && !t.include?("\r") && t.include?("Mario")
    end
  end

  test "an explicit non-default tenant_priority overrides the per-call priority" do
    stub_request(:post, @url).to_return(status: 200)
    NtfyNotifier.notify(title: "x", message: "y", priority: "low", tenant_priority: "max")
    assert_requested(:post, @url) { |req| req.headers["Priority"].to_s == "max" }
  end

  test "tenant_priority 'default' defers to the per-call priority (no flattening)" do
    stub_request(:post, @url).to_return(status: 200)
    NtfyNotifier.notify(title: "x", message: "y", priority: "high", tenant_priority: "default")
    assert_requested(:post, @url) { |req| req.headers["Priority"].to_s == "high" }
  end
end
