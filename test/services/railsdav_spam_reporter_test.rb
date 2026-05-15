require "test_helper"

class RailsdavSpamReporterTest < ActiveSupport::TestCase
  BASE = "http://railsdav.test:3000"
  TOKEN = "test-railsdav-token"

  setup do
    @prev_url = ENV["RAILSDAV_API_URL"]
    @prev_token = ENV["RAILSDAV_API_TOKEN"]
    ENV["RAILSDAV_API_URL"] = BASE
    ENV["RAILSDAV_API_TOKEN"] = TOKEN
  end

  teardown do
    ENV["RAILSDAV_API_URL"] = @prev_url
    ENV["RAILSDAV_API_TOKEN"] = @prev_token
  end

  test "returns ok: true on 2xx with bearer auth + JSON body" do
    stub_request(:post, "#{BASE}/api/spam_reports")
      .with(
        headers: { "Authorization" => "Bearer #{TOKEN}", "Content-Type" => "application/json" },
        body: hash_including("phone" => "+393331234567", "source" => "ntfy_report")
      )
      .to_return(status: 200, body: "{}")

    result = RailsdavSpamReporter.report("+393331234567", username: "nicola")
    assert result[:ok]
  end

  test "ok: false when env vars are missing" do
    ENV["RAILSDAV_API_URL"] = ""
    refute RailsdavSpamReporter.report("+393331234567")[:ok]

    ENV["RAILSDAV_API_URL"] = BASE
    ENV["RAILSDAV_API_TOKEN"] = ""
    refute RailsdavSpamReporter.report("+393331234567")[:ok]
  end

  test "ok: false when phone is blank" do
    refute RailsdavSpamReporter.report("")[:ok]
    refute RailsdavSpamReporter.report(nil)[:ok]
  end

  test "ok: false on 4xx and 5xx HTTP responses" do
    stub_request(:post, "#{BASE}/api/spam_reports").to_return(status: 401, body: "")
    result = RailsdavSpamReporter.report("+393331234567")
    refute result[:ok]
    assert_equal "http_401", result[:error]

    stub_request(:post, "#{BASE}/api/spam_reports").to_return(status: 500, body: "boom")
    result = RailsdavSpamReporter.report("+393331234567")
    refute result[:ok]
    assert_equal "http_500", result[:error]
  end

  test "ok: false on connection refused / timeout (no exception leaks)" do
    stub_request(:post, "#{BASE}/api/spam_reports").to_raise(Errno::ECONNREFUSED)
    refute RailsdavSpamReporter.report("+393331234567")[:ok]

    stub_request(:post, "#{BASE}/api/spam_reports").to_timeout
    refute RailsdavSpamReporter.report("+393331234567")[:ok]
  end

  test "omits username and notes when blank" do
    stub_request(:post, "#{BASE}/api/spam_reports").to_return(status: 200, body: "{}")
    RailsdavSpamReporter.report("+393331234567")
    assert_requested(:post, "#{BASE}/api/spam_reports") do |req|
      body = JSON.parse(req.body)
      !body.key?("submitted_by_username") && !body.key?("notes")
    end
  end
end
