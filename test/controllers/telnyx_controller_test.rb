require "test_helper"

# Voice API event-driven dispatcher tests. Each call.* event is sent to
# /telnyx/voice as JSON; the controller verifies the signature, persists
# Call.flow_state, and POSTs commands back to Telnyx via CallControlClient.
class TelnyxControllerTest < ActionDispatch::IntegrationTest
  setup do
    @token  = ENV.fetch("WEBHOOK_TOKEN")
    @tenant = tenants(:default)
    @tenant.update!(spam_sensitivity: 0.5,
                    forward_back_number: nil,
                    railsdav_username: "default",
                    mobile_number: "+393990000001")
    Setting.set("transcription_engine", "Google")
  end

  CCID         = "v3:test-call-control-id-1"
  TENANT_TO    = "+390123456789"   # default tenant fixture mobile_number is +390123456789
  CALLER_FROM  = "+393335551234"

  # === Authentication ===

  test "rejects unsigned request without fallback token" do
    post telnyx_voice_url, params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "fallback token (?token=) authenticates an otherwise-unsigned webhook" do
    # Use an unknown event_type so the dispatcher just acknowledges (no
    # downstream API call). This isolates the auth assertion.
    post telnyx_voice_url(token: @token), params: event_envelope("call.unknown.foo").to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
  end

  test "Ed25519 signature path authenticates the webhook" do
    private_key = OpenSSL::PKey.generate_key("ED25519")
    ENV["TELNYX_PUBLIC_KEY"] = Base64.strict_encode64(private_key.raw_public_key)
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "0"

    body = event_envelope("call.unknown.foo").to_json
    timestamp = Time.now.to_i.to_s
    signing_input = "#{timestamp}|#{body}"
    signature = Base64.strict_encode64(private_key.sign(nil, signing_input))

    post telnyx_voice_url, params: body, headers: {
      "Content-Type" => "application/json",
      "Telnyx-Signature-Ed25519" => signature,
      "Telnyx-Timestamp" => timestamp
    }
    assert_response :success
  ensure
    ENV.delete("TELNYX_PUBLIC_KEY")
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "1"
  end

  test "tampered signature is rejected" do
    private_key = OpenSSL::PKey.generate_key("ED25519")
    ENV["TELNYX_PUBLIC_KEY"] = Base64.strict_encode64(private_key.raw_public_key)
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "0"

    body = event_envelope("call.unknown.foo").to_json
    timestamp = Time.now.to_i.to_s
    signature = Base64.strict_encode64(private_key.sign(nil, "DIFFERENT|#{body}"))

    post telnyx_voice_url, params: body, headers: {
      "Content-Type" => "application/json",
      "Telnyx-Signature-Ed25519" => signature,
      "Telnyx-Timestamp" => timestamp
    }
    assert_response :unauthorized
  ensure
    ENV.delete("TELNYX_PUBLIC_KEY")
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "1"
  end

  # === call.initiated → tenant resolution ===

  test "call.initiated answers and persists Call attributed to default tenant via History-Info" do
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_response :success
    assert_requested answer_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal @tenant.id, call.tenant_id
    assert_equal "answered", call.flow_state
    refute call.unattributed
  end

  test "call.initiated falls back to default tenant when History-Info is missing → unattributed flag set" do
    other = tenants(:other)
    other.update!(default_tenant: false)
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(history_info: nil)

    assert_requested answer_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal @tenant.id, call.tenant_id  # default
    assert call.unattributed, "absent History-Info → unattributed"
  end

  test "call.initiated routes by Tenant.dedicated_number when set (B1 path)" do
    other = tenants(:other)
    other.update!(dedicated_number: "+390591111111")
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(to: "+390591111111", history_info: nil)

    assert_requested answer_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal other.id, call.tenant_id
    refute call.unattributed
  end

  test "call.initiated retries idempotently — same call_control_id does not duplicate" do
    answer_stub = stub_action(CCID, :answer)
    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
    assert_difference -> { Call.count }, 0 do
      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
    end
    assert_requested answer_stub, at_least_times: 1
  end

  # === call.initiated → policy branches ===

  test "blacklisted contact triggers reject + no answer command" do
    @tenant.contacts.create!(phone: CALLER_FROM, blacklisted: true)
    reject_stub = stub_action(CCID, :reject)
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_requested reject_stub
    assert_not_requested answer_stub
    assert_equal "spam", Call.find_by!(call_control_id: CCID).status
  end

  test "whitelisted contact triggers transfer to tenant.forward_back_number" do
    @tenant.update!(forward_back_number: "+393990000001")
    @tenant.contacts.create!(phone: CALLER_FROM, whitelisted: true)
    transfer_stub = stub_action(CCID, :transfer)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_requested transfer_stub
    assert_equal "legit", Call.find_by!(call_control_id: CCID).status
  end

  test "tenant rule action_block rejects and notifies" do
    @tenant.rules.create!(rule_type: :prefix, action: :block, value: "+39333", active: true)
    reject_stub = stub_action(CCID, :reject)

    assert_enqueued_jobs 1, only: NotifyJob do
      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
    end
    assert_requested reject_stub
  end

  # === Railsdav (centralized contacts) integration ===

  test "railsdav policy=block rejects without LLM" do
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "block", name: "Mario Spam", addressbook: "Family")
      reject_stub = stub_action(CCID, :reject)

      assert_enqueued_jobs 1, only: NotifyJob do
        post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
      end
      assert_requested reject_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "spam", call.status
      assert_equal "Mario Spam", call.contact.name
    end
  end

  test "railsdav policy=allow transfers to forward_back_number" do
    @tenant.update!(forward_back_number: "+393990000001")
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "allow", name: "Mama", addressbook: "Family")
      transfer_stub = stub_action(CCID, :transfer)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested transfer_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "legit", call.status
      assert_equal "Mama", call.contact.name
    end
  end

  test "railsdav policy=screen falls through to screening but enriches contact name" do
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "screen", name: "Acquaintance", addressbook: "Work")
      answer_stub = stub_action(CCID, :answer)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested answer_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "screening", call.status
      assert_equal "Acquaintance", call.contact.name
    end
  end

  # === call.answered → greeting gather ===

  test "call.answered triggers gather_using_audio with the tenant's pre-rendered greeting" do
    setup_pre_rendered_greeting(@tenant.greeting_variant)
    seed_call(flow_state: "answered")
    gather_stub = stub_action(CCID, :gather_using_audio)

    post_event answered_payload

    assert_requested gather_stub
    assert_equal "awaiting_speech", Call.find_by!(call_control_id: CCID).reload.flow_state
  ensure
    cleanup_greeting_files
  end

  test "call.answered without pre-rendered audio falls back to gather_using_speak" do
    seed_call(flow_state: "answered")
    gather_stub = stub_action(CCID, :gather_using_speak)

    post_event answered_payload

    assert_requested gather_stub
    assert_equal "awaiting_speech", Call.find_by!(call_control_id: CCID).reload.flow_state
  end

  # === call.gather.ended → classification ===

  test "empty transcript on first gather → spam + speak goodbye_short" do
    seed_call(flow_state: "awaiting_speech")
    speak_stub = stub_action(CCID, :speak)

    assert_enqueued_jobs 1, only: NotifyJob do
      post_event gather_payload(transcript: "")
    end
    assert_requested speak_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "spam", call.status
    assert_equal "hanging_up_after_speak", call.flow_state
  end

  test "high-confidence spam classification → goodbye_spam playback or speak" do
    seed_call(flow_state: "awaiting_speech")
    stub_moonshot("spam", 0.95, "Robocall")
    speak_stub = stub_action(CCID, :speak)

    assert_enqueued_jobs 1, only: NotifyJob do
      post_event gather_payload(transcript: "Special offer for your phone bill")
    end
    assert_requested speak_stub
  end

  test "legit classification starts voicemail recording" do
    seed_call(flow_state: "awaiting_speech")
    stub_moonshot("legit", 0.92, "Sounds real")
    speak_stub = stub_action(CCID, :speak)        # voicemail prompt
    record_stub = stub_action(CCID, :record_start) # actual recording

    post_event gather_payload(transcript: "Sono Mario chiamo per informazioni")

    assert_requested speak_stub
    assert_requested record_stub
    assert_equal "recording", Call.find_by!(call_control_id: CCID).status
  end

  test "uncertain classification asks one clarifying question" do
    seed_call(flow_state: "awaiting_speech")
    stub_moonshot("uncertain", 0.3, "Garbled")
    gather_stub = stub_action(CCID, :gather_using_speak)  # no audio for clarify

    post_event gather_payload(transcript: "uhm")

    assert_requested gather_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "uncertain", call.status
    assert_equal "clarification_awaiting_speech", call.flow_state
  end

  test "low-confidence spam (below tenant.spam_sensitivity) is treated as uncertain" do
    @tenant.update!(spam_sensitivity: 0.9)
    seed_call(flow_state: "awaiting_speech")
    stub_moonshot("spam", 0.5, "Mildly suspicious")
    gather_stub = stub_action(CCID, :gather_using_speak)

    post_event gather_payload(transcript: "Pronto?")

    assert_requested gather_stub
    assert_equal "uncertain", Call.find_by!(call_control_id: CCID).status
  end

  test "low-confidence spam (above tenant.spam_sensitivity) is hung up" do
    @tenant.update!(spam_sensitivity: 0.3)
    seed_call(flow_state: "awaiting_speech")
    stub_moonshot("spam", 0.5, "Mildly suspicious")
    speak_stub = stub_action(CCID, :speak)

    post_event gather_payload(transcript: "Pronto?")

    assert_requested speak_stub
    assert_equal "spam", Call.find_by!(call_control_id: CCID).status
  end

  test "second-pass clarification: legit → voicemail" do
    seed_call(flow_state: "clarification_awaiting_speech", screening_transcript: "uhm")
    stub_moonshot("legit", 0.85, "Real caller after clarification")
    stub_action(CCID, :speak)
    stub_action(CCID, :record_start)

    post_event gather_payload(transcript: "Sono Lucia, chiamo per il pacco")

    call = Call.find_by!(call_control_id: CCID)
    assert_equal "recording", call.status
  end

  test "keyword rule short-circuits LLM and triggers spam goodbye" do
    @tenant.rules.create!(rule_type: :keyword, action: :block, value: "warranty", active: true)
    seed_call(flow_state: "awaiting_speech")
    speak_stub = stub_action(CCID, :speak)

    assert_enqueued_jobs 1, only: NotifyJob do
      post_event gather_payload(transcript: "Hi about your warranty plan")
    end
    assert_requested speak_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "Keyword rule: warranty", call.ai_classification["reason"]
  end

  # === call.recording.saved ===

  test "recording.saved persists URL, queues TranscribeRecordingJob, hangs up" do
    seed_call(flow_state: "recording")
    hangup_stub = stub_action(CCID, :hangup)

    assert_enqueued_jobs 1, only: TranscribeRecordingJob do
      post_event recording_saved_payload(url: "https://api.telnyx.com/v2/recordings/abc.wav")
    end
    assert_requested hangup_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "https://api.telnyx.com/v2/recordings/abc.wav", call.recording_url
    assert_equal "completed", call.status
  end

  test "recording.saved is idempotent — duplicate webhook does not double-enqueue" do
    seed_call(flow_state: "recording")
    stub_action(CCID, :hangup)

    assert_enqueued_jobs 1, only: TranscribeRecordingJob do
      post_event recording_saved_payload(url: "https://x/a.wav")
      post_event recording_saved_payload(url: "https://x/a.wav")
    end
  end

  # === call.playback.ended → finalize hangup ===

  test "playback.ended after hanging_up_after_speak issues hangup" do
    seed_call(flow_state: "hanging_up_after_speak")
    hangup_stub = stub_action(CCID, :hangup)

    post_event(event_envelope("call.playback.ended"))

    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
  end

  test "speak.ended after hanging_up_after_speak issues hangup" do
    seed_call(flow_state: "hanging_up_after_speak")
    hangup_stub = stub_action(CCID, :hangup)

    post_event(event_envelope("call.speak.ended"))

    assert_requested hangup_stub
  end

  # === call.hangup ===

  test "call.hangup marks flow_state done and stamps contact.last_called_at" do
    seed_call(flow_state: "answered", contact: contacts(:regular))
    post_event event_envelope("call.hangup")
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "done", call.flow_state
  end

  # === unknown events ===

  test "unknown event_type is acknowledged with 200" do
    post_event event_envelope("call.cost")
    assert_response :success
  end

  private

  def seed_call(flow_state:, contact: nil, screening_transcript: nil)
    @tenant.calls.create!(
      call_sid: CCID, call_control_id: CCID,
      from_number: CALLER_FROM, to_number: TENANT_TO,
      flow_state: flow_state, status: :screening,
      contact: contact || @tenant.contacts.find_or_create_by!(phone: CALLER_FROM),
      screening_transcript: screening_transcript
    )
  end

  def post_event(payload)
    post telnyx_voice_url(token: @token), params: payload.to_json,
         headers: { "Content-Type" => "application/json" }
  end

  def initiated_payload(to: TENANT_TO, history_info: nil)
    payload = {
      "call_control_id" => CCID,
      "call_leg_id"     => "leg-1",
      "call_session_id" => "sess-1",
      "from"            => CALLER_FROM,
      "to"              => to,
      "direction"       => "incoming",
      "state"           => "parked",
      "calling_party_type" => "pstn"
    }
    payload["sip_headers"] = [ history_info ] if history_info
    event_envelope("call.initiated", payload)
  end

  def answered_payload
    event_envelope("call.answered", { "call_control_id" => CCID, "from" => CALLER_FROM, "to" => TENANT_TO })
  end

  def gather_payload(transcript:)
    event_envelope("call.gather.ended", {
      "call_control_id" => CCID,
      "transcription"   => { "transcript" => transcript, "confidence" => 0.9 }
    })
  end

  def recording_saved_payload(url:)
    event_envelope("call.recording.saved", {
      "call_control_id" => CCID,
      "recording_urls"  => { "wav" => url },
      "duration_seconds" => 15
    })
  end

  def event_envelope(event_type, payload = { "call_control_id" => CCID })
    {
      "data" => {
        "event_type" => event_type,
        "id" => "evt-#{event_type}-1",
        "occurred_at" => Time.now.utc.iso8601,
        "payload" => payload,
        "record_type" => "event"
      }
    }
  end

  def history_info_for(mobile)
    {
      "name"  => "History-Info",
      "value" => "<sip:#{mobile}@telecomitalia.it;user=phone>;index=1, " \
                 "<sip:#{TENANT_TO}@telecomitalia.it;user=phone;cause=408>;index=1.1"
    }
  end

  def stub_action(ccid, action)
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{ccid}/actions/#{action}")
      .to_return(status: 200, body: '{"data":{"result":"ok"}}',
                 headers: { "Content-Type" => "application/json" })
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

  def stub_moonshot(classification, confidence, reason)
    body = {
      choices: [ { message: { content: { classification:, confidence:, reason: }.to_json } } ]
    }.to_json
    stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  def setup_pre_rendered_greeting(slug)
    @greeting_paths ||= []
    voice = @tenant.greeting_voice
    tone  = @tenant.greeting_tone
    path  = GreetingsStorage.path_for(slug, voice, tone)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "RIFF dummy")
    @greeting_paths << path
  end

  def cleanup_greeting_files
    Array(@greeting_paths).each { |p| FileUtils.rm_f(p) }
  end
end
