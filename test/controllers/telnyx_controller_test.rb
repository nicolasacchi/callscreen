require "test_helper"

class TelnyxControllerTest < ActionDispatch::IntegrationTest
  setup do
    @token = ENV.fetch("WEBHOOK_TOKEN")
    Setting.set("spam_sensitivity", "0.5")
  end

  # === Authentication ===

  test "rejects voice webhook with no token" do
    post telnyx_voice_url, params: { CallSid: "abc123", From: "+393331111111", To: "+390000000000" }
    assert_response :unauthorized
  end

  test "rejects voice webhook with wrong token" do
    post telnyx_voice_url(token: "nope"), params: { CallSid: "abc123", From: "+393331111111", To: "+390000000000" }
    assert_response :unauthorized
  end

  test "rejects voice webhook with malformed CallSid (path traversal)" do
    post telnyx_voice_url(token: @token),
         params: { CallSid: "../../etc/passwd", From: "+393331111111", To: "+390000000000" }
    assert_response :bad_request
    assert_equal 0, Call.where(from_number: "+393331111111").where("call_sid LIKE ?", "%passwd%").count
  end

  test "rejects voice webhook with empty CallSid" do
    post telnyx_voice_url(token: @token),
         params: { CallSid: "", From: "+393331111111", To: "+390000000000" }
    assert_response :bad_request
  end

  # === Voice action: routing ===

  test "voice on new caller creates contact + screening call and returns Gather TeXML" do
    assert_difference -> { Call.count } => 1, -> { Contact.count } => 1 do
      post telnyx_voice_url(token: @token),
           params: { CallSid: "fresh-call-001", From: "+393339999999", To: "+390123456789" }
    end

    assert_response :success
    assert_equal "text/xml", @response.media_type
    assert_match(/<Gather/, @response.body)
    assert_match(/<Say/, @response.body)

    call = Call.find_by!(call_sid: "fresh-call-001")
    assert_equal "screening", call.status
    assert_equal "+393339999999", call.from_number
  end

  test "voice on blacklisted contact returns Reject TeXML and marks call spam" do
    spammer = contacts(:spammer)
    post telnyx_voice_url(token: @token),
         params: { CallSid: "block-call-001", From: spammer.phone, To: "+390123456789" }
    assert_response :success
    assert_match(/<Reject\/>/, @response.body)
    assert_equal "spam", Call.find_by!(call_sid: "block-call-001").status
  end

  test "voice on whitelisted contact with FORWARD_NUMBER returns Dial TeXML" do
    vip = contacts(:vip)
    ENV["FORWARD_NUMBER"] = "+390987654321"
    post telnyx_voice_url(token: @token),
         params: { CallSid: "vip-call-001", From: vip.phone, To: "+390123456789" }
    assert_response :success
    assert_match(/<Dial>\+390987654321<\/Dial>/, @response.body)
    assert_equal "legit", Call.find_by!(call_sid: "vip-call-001").status
  ensure
    ENV.delete("FORWARD_NUMBER")
  end

  test "voice on whitelisted contact without FORWARD_NUMBER records voicemail" do
    vip = contacts(:vip)
    ENV.delete("FORWARD_NUMBER")
    post telnyx_voice_url(token: @token),
         params: { CallSid: "vip-vm-001", From: vip.phone, To: "+390123456789" }
    assert_response :success
    assert_match(/<Record/, @response.body)
    assert_equal "recording", Call.find_by!(call_sid: "vip-vm-001").status
  end

  test "voice with phone matching block prefix rule returns Reject" do
    rules(:block_premium).update!(value: "+393391")
    post telnyx_voice_url(token: @token),
         params: { CallSid: "premium-001", From: "+393391234567", To: "+390123456789" }
    assert_response :success
    assert_match(/<Reject\/>/, @response.body)
    assert_equal "spam", Call.find_by!(call_sid: "premium-001").status
    assert_equal 1, rules(:block_premium).reload.hit_count
  end

  test "voice does NOT double-increment contact calls_count via counter cache" do
    regular = contacts(:regular)
    initial_count = regular.calls_count

    post telnyx_voice_url(token: @token),
         params: { CallSid: "counter-test-001", From: regular.phone, To: "+390123456789" }
    assert_response :success
    regular.reload

    # Counter cache adds 1; the manual increment! that used to add another 1 is gone.
    assert_equal initial_count + 1, regular.calls_count, "calls_count must increment exactly once per call"
  end

  # === Screen action ===

  test "screen with empty SpeechResult marks spam and hangs up" do
    call = calls(:screening)
    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "" }
    assert_response :success
    assert_match(/<Hangup\/>/, @response.body)
    assert_equal "spam", call.reload.status
  end

  test "screen with keyword-block rule short-circuits LLM" do
    call = calls(:screening)
    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "I am calling about your warranty" }
    assert_response :success
    assert_match(/<Hangup\/>/, @response.body)
    assert_equal "spam", call.reload.status
    assert_equal "Keyword rule: warranty", call.ai_classification["reason"]
  end

  test "screen with LLM spam classification hangs up" do
    call = calls(:screening)
    stub_openrouter("spam", 0.95, "Robocall pattern detected")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "Special offer for your phone bill" }
    assert_response :success
    assert_match(/<Hangup\/>/, @response.body)
    assert_equal "spam", call.reload.status
    assert_equal 0.95, call.ai_classification["confidence"]
  end

  test "screen with LLM legit classification records voicemail" do
    call = calls(:screening)
    stub_openrouter("legit", 0.9, "Sounds like a real caller")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "Sono Mario, chiamo per il tuo amico" }
    assert_response :success
    assert_match(/<Record/, @response.body)
    assert_equal "legit", call.reload.status
  end

  test "screen with LLM uncertain records voicemail" do
    call = calls(:screening)
    stub_openrouter("uncertain", 0.3, "Garbled speech")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "uhm... ah... ciao?" }
    assert_response :success
    assert_match(/<Record/, @response.body)
    assert_equal "uncertain", call.reload.status
  end

  test "screen below sensitivity threshold downgrades spam to uncertain" do
    Setting.set("spam_sensitivity", "0.9")
    call = calls(:screening)
    stub_openrouter("spam", 0.6, "Slightly suspicious")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "Buongiorno" }
    assert_response :success
    assert_match(/<Record/, @response.body)
    assert_equal "uncertain", call.reload.status
  end

  test "screen handles HTTP error from OpenRouter gracefully" do
    call = calls(:screening)
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(status: 500, body: "boom")

    post telnyx_screen_url(token: @token),
         params: { CallSid: call.call_sid, SpeechResult: "ciao" }
    assert_response :success
    # Falls through to uncertain → voicemail recording
    assert_match(/<Record/, @response.body)
  end

  # === Recording action ===

  test "recording action enqueues TranscribeRecordingJob and hangs up" do
    call = calls(:screening)
    assert_enqueued_with(job: TranscribeRecordingJob, args: [ call.id ]) do
      post telnyx_recording_url(token: @token),
           params: {
             CallSid: call.call_sid,
             RecordingUrl: "https://api.telnyx.com/recordings/abc.wav",
             RecordingDuration: "42"
           }
    end
    assert_response :success
    assert_match(/<Hangup\/>/, @response.body)
    call.reload
    assert_equal "completed", call.status
    assert_equal 42, call.duration_seconds
  end

  # === Status action ===

  test "status action updates call duration and contact last_called_at" do
    call = calls(:legit_completed)
    travel_to Time.zone.parse("2026-04-25 10:00:00") do
      post telnyx_status_url(token: @token),
           params: { CallSid: call.call_sid, CallDuration: "55" }
      assert_response :success
      call.reload
      assert_equal 55, call.duration_seconds
      assert_in_delta Time.zone.parse("2026-04-25 10:00:00"), call.contact.reload.last_called_at, 1.second
    end
  end

  test "status action with unknown CallSid is a no-op 200" do
    post telnyx_status_url(token: @token), params: { CallSid: "not-a-real-sid", CallDuration: "5" }
    assert_response :success
  end

  private

  def stub_openrouter(classification, confidence, reason)
    body = {
      choices: [ { message: { content: { classification:, confidence:, reason: }.to_json } } ]
    }.to_json
    stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(
      status: 200,
      body: body,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
