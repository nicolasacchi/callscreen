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
    assert_equal 7, result.contact_id
  end

  test "match: false with no spam fields → Result(matched?: false, spam_global: false)" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup})
      .to_return(status: 200, body: { match: false }.to_json, headers: { "Content-Type" => "application/json" })

    result = RailsdavContactsClient.lookup("+393331234567")
    refute result.matched?
    refute result.spam_global?
  end

  test "match: false with spam_global: true returns Result with spam_global populated" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: {
        match: false,
        spam_global: true,
        spam_metadata: { source: "ntfy_report", report_count: 4, first_reported_at: "2026-04-01T12:00:00Z" }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    refute result.matched?, "no contact in address book → matched? stays false"
    assert result.spam_global?, "but spam_global must be true so the TelnyxController gate fires"
    assert_equal "ntfy_report", result.spam_metadata["source"]
    assert_equal 4, result.spam_metadata["report_count"]
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

  test "captures last_seen_at and notes from spam_metadata (the WHY + recency flow down)" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: { match: false, spam_global: true,
              spam_metadata: { source: "ntfy_report", report_count: 9,
                               last_seen_at: "2026-06-14T00:00:00Z", notes: "AI: telemarketing" } }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.spam_global?
    assert_equal "AI: telemarketing", result.spam_metadata["notes"]
    assert_equal "2026-06-14T00:00:00Z", result.spam_metadata["last_seen_at"]
  end

  test "returns MISS for a non-E.164 phone without calling railsdav" do
    assert_equal RailsdavContactsClient::MISS, RailsdavContactsClient.lookup("anonymous")
    assert_not_requested :get, %r{railsdav\.test:3000/api/contact_lookup}
  end

  test "captures kind and (sanitized, bounded) groups for a matched contact" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { match: true, name: "Bob", policy: "screen", contact_id: 5,
              kind: "individual", groups: [ "Family", "Doctors\r\nX" ] }.to_json
    )
    r = RailsdavContactsClient.lookup("+393331234567")
    assert_equal "individual", r.kind
    assert_equal [ "Family", "DoctorsX" ], r.groups # control chars stripped
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

  test "legacy response without spam fields defaults spam_global to false" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: { match: true, name: "Mario", policy: "screen", addressbook: "Family", contact_id: 1 }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.matched?
    refute result.spam_global?
    assert_equal({}, result.spam_metadata)
  end

  test "parses spam_global and spam_metadata when present" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: {
        match: true, name: "Mario", policy: "screen", addressbook: "Public",
        spam_global: true,
        spam_metadata: { first_reported_at: "2026-04-01T12:00:00Z", source: "feed:tellows", report_count: 7 }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.spam_global?
    assert_equal "2026-04-01T12:00:00Z", result.spam_metadata["first_reported_at"]
    assert_equal "feed:tellows", result.spam_metadata["source"]
    assert_equal 7, result.spam_metadata["report_count"]
  end

  test "drops unknown spam_metadata keys (defense in depth)" do
    stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
      status: 200,
      body: {
        match: true, name: "Mario", policy: "screen", addressbook: "Public",
        spam_global: true,
        spam_metadata: { source: "ntfy_report", report_count: 1, secret_token: "leak", admin: true }
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = RailsdavContactsClient.lookup("+393331234567")
    assert result.spam_global?
    refute result.spam_metadata.key?("secret_token")
    refute result.spam_metadata.key?("admin")
  end

  test "coerces malformed spam_metadata (string, array) to empty hash" do
    [ "weird-string", [ "a", "b" ] ].each do |bad_payload|
      stub_request(:get, %r{railsdav\.test:3000/api/contact_lookup}).to_return(
        status: 200,
        body: {
          match: true, name: "Mario", policy: "screen", addressbook: "Public",
          spam_global: true,
          spam_metadata: bad_payload
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      result = RailsdavContactsClient.lookup("+393331234567")
      assert result.spam_global?
      assert_equal({}, result.spam_metadata)
    end
  end
end
