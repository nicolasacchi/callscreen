require "test_helper"

class RailsdavAllowReporterTest < ActiveSupport::TestCase
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

  test "POSTs phone/name/username with bearer auth and returns ok on 2xx" do
    stub_request(:post, "#{BASE}/api/contacts/upsert_allow")
      .with(
        headers: { "Authorization" => "Bearer #{TOKEN}", "Content-Type" => "application/json" },
        body: hash_including("phone" => "+393331234567", "name" => "Mario", "username" => "nicola")
      )
      .to_return(status: 200, body: "{}")

    assert RailsdavAllowReporter.report("+393331234567", name: "Mario", username: "nicola")[:ok]
  end

  test "omits name and username when blank" do
    stub_request(:post, "#{BASE}/api/contacts/upsert_allow").to_return(status: 200, body: "{}")
    RailsdavAllowReporter.report("+393331234567")
    assert_requested(:post, "#{BASE}/api/contacts/upsert_allow") do |req|
      body = JSON.parse(req.body)
      !body.key?("name") && !body.key?("username") && body["phone"] == "+393331234567"
    end
  end

  test "fails fast as invalid_phone for a non-E.164 number without calling railsdav" do
    result = RailsdavAllowReporter.report("anonymous")
    refute result[:ok]
    assert_equal "invalid_phone", result[:error]
    assert_not_requested :post, "#{BASE}/api/contacts/upsert_allow"
  end

  test "ok: false when env config is missing" do
    ENV["RAILSDAV_API_URL"] = ""
    refute RailsdavAllowReporter.report("+393331234567")[:ok]
  end

  test "ok: false on a non-2xx response (best-effort, never raises)" do
    stub_request(:post, "#{BASE}/api/contacts/upsert_allow").to_return(status: 503, body: "boom")
    result = RailsdavAllowReporter.report("+393331234567")
    refute result[:ok]
    assert_equal "http_503", result[:error]
  end
end
