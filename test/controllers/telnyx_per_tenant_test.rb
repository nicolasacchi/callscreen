require "test_helper"

# Phase 3 — verify per-tenant settings actually drive controller behavior
# (still TeXML; Phase 4 replaces this with Voice API).
class TelnyxPerTenantTest < ActionDispatch::IntegrationTest
  setup do
    @token  = ENV.fetch("WEBHOOK_TOKEN")
    @tenant = tenants(:default)
  end

  test "tenant.spam_sensitivity controls the high/low confidence threshold" do
    @tenant.update!(spam_sensitivity: 0.95)
    call = calls(:screening)
    stub_moonshot("spam", 0.6, "Slightly suspicious")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "Buongiorno" }
    assert_response :success
    # 0.6 < 0.95 → falls below threshold → clarify gather
    assert_match(/<Gather/, @response.body)
    assert_equal "uncertain", call.reload.status
  end

  test "tenant.spam_sensitivity below the conf flips the same call to high-confidence spam" do
    @tenant.update!(spam_sensitivity: 0.3)
    call = calls(:screening)
    stub_moonshot("spam", 0.6, "Slightly suspicious")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "Buongiorno" }
    assert_response :success
    # 0.6 >= 0.3 → high-confidence spam → hangup
    assert_match(/<Hangup/, @response.body)
    assert_equal "spam", call.reload.status
  end

  test "tenant.forward_back_number is used for whitelist Dial" do
    @tenant.update!(forward_back_number: "+390000111222")
    vip = contacts(:vip)
    post telnyx_voice_url(token: @token),
         params: { CallSid: "ten-fb-1", From: vip.phone, To: "+390123456789" }
    assert_response :success
    assert_match(/<Dial[^>]*>\+390000111222<\/Dial>/, @response.body)
  end

  test "tenant.greeting_language flows into the Gather attribute" do
    @tenant.update!(greeting_language: "en-US")
    post telnyx_voice_url(token: @token),
         params: { CallSid: "ten-lang-1", From: "+393335550001", To: "+390123456789" }
    assert_response :success
    assert_match(/language="en-US"/, @response.body)
  end

  test "tenant.railsdav_username is passed to the lookup endpoint" do
    @tenant.update!(railsdav_username: "alice")

    with_railsdav_env do
      stub_railsdav("+393335550002", username: "alice", policy: "screen", name: "Tenant Alice", addressbook: "Family")
      post telnyx_voice_url(token: @token),
           params: { CallSid: "ten-rd-1", From: "+393335550002", To: "+390123456789" }
      assert_response :success
      assert_equal "Tenant Alice", Call.find_by!(call_sid: "ten-rd-1").contact.name
    end
  end

  test "tenant.ntfy_url overrides ENV[NTFY_URL]" do
    @tenant.update!(ntfy_url: "http://tenant-ntfy.test/x")
    call = @tenant.calls.create!(
      call_sid: "ntfy-1", from_number: "+393335550003", status: :spam,
      ai_classification: { "classification" => "spam", "confidence" => 0.99, "reason" => "test" },
      contact: contacts(:spammer)
    )
    stub = stub_request(:post, "http://tenant-ntfy.test/x").to_return(status: 200, body: "")
    NotifyJob.new.perform(call.id)
    assert_requested stub
  end

  private

  def with_railsdav_env
    prev_url = ENV["RAILSDAV_API_URL"]
    prev_token = ENV["RAILSDAV_API_TOKEN"]
    ENV["RAILSDAV_API_URL"] = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "test-railsdav-token"
    yield
  ensure
    ENV["RAILSDAV_API_URL"] = prev_url
    ENV["RAILSDAV_API_TOKEN"] = prev_token
  end

  def stub_railsdav(phone, policy:, name:, addressbook:, username:)
    stub_request(:get, "http://railsdav.test:3000/api/contact_lookup")
      .with(query: { phone: phone, username: username })
      .to_return(
        status: 200,
        body: { match: true, name: name, policy: policy, addressbook: addressbook, contact_id: 1 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_moonshot(classification, confidence, reason)
    body = {
      choices: [ { message: { content: { classification:, confidence:, reason: }.to_json } } ]
    }.to_json
    stub_request(:post, "https://api.moonshot.ai/v1/chat/completions").to_return(
      status: 200,
      body: body,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
