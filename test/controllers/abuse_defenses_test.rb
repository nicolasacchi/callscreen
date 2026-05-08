require "test_helper"

# Phase 5 — verifies the abuse-mitigation hooks: rate-limit per caller +
# auto-blacklist after N spam classifications. Both per-tenant tunable.
class AbuseDefensesTest < ActionDispatch::IntegrationTest
  setup do
    @token  = ENV.fetch("WEBHOOK_TOKEN")
    @tenant = tenants(:default)
    @tenant.update!(
      mobile_number: "+393990000001",
      forward_back_number: nil,
      max_calls_per_caller_per_day: 5,
      auto_blacklist_threshold: 3,
      auto_blacklist_window_days: 7
    )
  end

  CCID         = "v3:abuse-test"
  CALLER_FROM  = "+393335551234"
  TENANT_TO    = "+390123456789"

  test "rate limit: 6th call from same caller in 15min is rejected without LLM" do
    contact = @tenant.contacts.create!(phone: CALLER_FROM)
    5.times do |i|
      @tenant.calls.create!(
        call_sid: "rl-prev-#{i}", call_control_id: "rl-prev-#{i}",
        from_number: CALLER_FROM, contact: contact, status: :spam,
        created_at: (i * 2).minutes.ago
      )
    end
    reject_stub = stub_action(CCID, :reject)
    answer_stub = stub_action(CCID, :answer)
    moonshot_stub = stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")

    assert_enqueued_jobs 1, only: NotifyJob do
      post_event initiated_payload
    end
    assert_requested reject_stub
    assert_not_requested answer_stub
    assert_not_requested moonshot_stub  # LLM never called for rate-limited callers

    new_call = Call.find_by!(call_control_id: CCID)
    assert_equal "spam", new_call.status
    assert_match(/Rate limited/, new_call.ai_classification["reason"])
  end

  test "rate limit: counts ignore old calls outside the 15min window" do
    contact = @tenant.contacts.create!(phone: CALLER_FROM)
    6.times do |i|
      @tenant.calls.create!(
        call_sid: "rl-old-#{i}", call_control_id: "rl-old-#{i}",
        from_number: CALLER_FROM, contact: contact, status: :spam,
        created_at: 30.hours.ago - i.minutes
      )
    end
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload

    assert_requested answer_stub  # not rate-limited; old calls don't count
    assert_equal "screening", Call.find_by!(call_control_id: CCID).status
  end

  test "rate limit: whitelisted contact is exempt" do
    contact = @tenant.contacts.create!(phone: CALLER_FROM, whitelisted: true)
    20.times do |i|
      @tenant.calls.create!(
        call_sid: "rl-w-#{i}", call_control_id: "rl-w-#{i}",
        from_number: CALLER_FROM, contact: contact, status: :legit,
        created_at: i.minutes.ago
      )
    end
    @tenant.update!(forward_back_number: "+393990000001")
    transfer_stub = stub_action(CCID, :transfer)

    post_event initiated_payload

    assert_requested transfer_stub
    assert_equal "legit", Call.find_by!(call_control_id: CCID).status
  end

  test "rate limit: railsdav-allowed contact is exempt" do
    contact = @tenant.contacts.create!(phone: CALLER_FROM)
    20.times do |i|
      @tenant.calls.create!(
        call_sid: "rl-rd-#{i}", call_control_id: "rl-rd-#{i}",
        from_number: CALLER_FROM, contact: contact, status: :legit,
        created_at: i.minutes.ago
      )
    end
    @tenant.update!(forward_back_number: "+393990000001")

    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "allow", name: "Trusted", addressbook: "Family")
      transfer_stub = stub_action(CCID, :transfer)
      post_event initiated_payload
      assert_requested transfer_stub
    end
  end

  # Auto-blacklist now happens in ScreeningJob (after Whisper transcribes the
  # screening recording). See test/jobs/screening_job_test.rb.

  private

  def post_event(payload)
    post telnyx_voice_url(token: @token), params: payload.to_json,
         headers: { "Content-Type" => "application/json" }
  end

  def initiated_payload(history_info: { "name" => "History-Info",
                                        "value" => "<sip:#{@tenant.mobile_number}@x>;index=1, <sip:#{TENANT_TO}@x;cause=408>;index=1.1" })
    {
      "data" => {
        "event_type" => "call.initiated",
        "id" => "evt-init-1",
        "occurred_at" => Time.now.utc.iso8601,
        "payload" => {
          "call_control_id" => CCID,
          "from" => CALLER_FROM,
          "to" => TENANT_TO,
          "direction" => "incoming",
          "state" => "parked",
          "sip_headers" => history_info ? [ history_info ] : nil
        },
        "record_type" => "event"
      }
    }
  end

  def gather_payload(transcript:)
    {
      "data" => {
        "event_type" => "call.gather.ended",
        "id" => "evt-gather-1",
        "occurred_at" => Time.now.utc.iso8601,
        "payload" => {
          "call_control_id" => CCID,
          "transcription" => { "transcript" => transcript, "confidence" => 0.9 }
        },
        "record_type" => "event"
      }
    }
  end

  def stub_action(ccid, action)
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{ccid}/actions/#{action}")
      .to_return(status: 200, body: '{"data":{"result":"ok"}}',
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_moonshot(classification, confidence, reason)
    body = {
      choices: [ { message: { content: { classification:, confidence:, reason: }.to_json } } ]
    }.to_json
    stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  def with_railsdav_env
    prev_url   = ENV["RAILSDAV_API_URL"]
    prev_token = ENV["RAILSDAV_API_TOKEN"]
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "test-railsdav-token"
    yield
  ensure
    ENV["RAILSDAV_API_URL"]   = prev_url
    ENV["RAILSDAV_API_TOKEN"] = prev_token
  end

  def stub_railsdav(phone, username:, policy:, name:, addressbook:)
    stub_request(:get, "http://railsdav.test:3000/api/contact_lookup")
      .with(query: { phone: phone, username: username })
      .to_return(
        status: 200,
        body: { match: true, name: name, policy: policy, addressbook: addressbook, contact_id: 1 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
