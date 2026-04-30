require "test_helper"

class RailsdavContactsClientTest < ActiveSupport::TestCase
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

  test "returns MISS when phone is blank" do
    assert_equal RailsdavContactsClient::MISS, RailsdavContactsClient.lookup(nil)
    assert_equal RailsdavContactsClient::MISS, RailsdavContactsClient.lookup("")
  end

  test "returns MISS when env vars unset" do
    ENV["RAILSDAV_API_URL"] = ""
    assert_equal RailsdavContactsClient::MISS, RailsdavContactsClient.lookup("+393331234567")

    ENV["RAILSDAV_API_URL"] = BASE
    ENV["RAILSDAV_API_TOKEN"] = ""
    assert_equal RailsdavContactsClient::MISS, RailsdavContactsClient.lookup("+393331234567")
  end

  test "returns Result on a 200 match response" do
    stub_request(:get, "#{BASE}/api/contact_lookup")
      .with(query: { phone: "+393331234567" }, headers: { "Authorization" => "Bearer #{TOKEN}" })
      .to_return(
        status: 200,
        body: { match: true, name: "Mario", policy: "allow", addressbook: "Family", contact_id: 7 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.matched?
    assert_equal "Mario", result.name
    assert_equal "allow", result.policy
    assert_equal "Family", result.addressbook
  end

  test "returns MISS when API responds match: false" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup})
      .to_return(status: 200, body: { match: false }.to_json, headers: { "Content-Type" => "application/json" })

    refute RailsdavContactsClient.lookup("+393331234567").matched?
  end

  test "returns MISS on 4xx and 5xx" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(status: 401, body: "")
    refute RailsdavContactsClient.lookup("+393331234567").matched?

    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(status: 500, body: "boom")
    refute RailsdavContactsClient.lookup("+393331234567").matched?
  end

  test "returns MISS on connection refused" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_raise(Errno::ECONNREFUSED)
    refute RailsdavContactsClient.lookup("+393331234567").matched?
  end

  test "returns MISS on timeout" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_timeout
    refute RailsdavContactsClient.lookup("+393331234567").matched?
  end

  test "strips control chars and caps name/addressbook length (defense against injection)" do
    payload_name = "Mario\r\n<script>alert(1)</script>" + ("x" * 1000)
    payload_ab = "Family\nReason: PWNED\r\n"
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: { match: true, name: payload_name, policy: "screen", addressbook: payload_ab, contact_id: 1 }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.matched?
    refute_includes result.name.to_s, "\n"
    refute_includes result.name.to_s, "\r"
    assert_operator result.name.to_s.length, :<=, RailsdavContactsClient::MAX_STRING_LEN
    refute_includes result.addressbook.to_s, "\n"
  end

  test "coerces invalid policy values to nil" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: { match: true, name: "Mario", policy: "evil", addressbook: "Family", contact_id: 1 }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.matched?
    assert_nil result.policy
  end

  test "tolerates trailing slash on RAILSDAV_API_URL" do
    ENV["RAILSDAV_API_URL"] = "#{BASE}/"
    stub_request(:get, "#{BASE}/api/contact_lookup")
      .with(query: { phone: "+393331234567" })
      .to_return(
        status: 200,
        body: { match: true, name: "Mario", policy: "allow", addressbook: "Family", contact_id: 1 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.matched?
    assert_equal "allow", result.policy
  end
end
