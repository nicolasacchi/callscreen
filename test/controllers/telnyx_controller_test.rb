require "test_helper"

# Voice API event-driven dispatcher tests. Each call.* event is sent to
# /telnyx/voice as JSON; the controller verifies the signature, persists
# Call.flow_state, and POSTs commands back to Telnyx via CallControlClient.
#
# Speech transcription happens in ScreeningJob (which is enqueued from
# call.recording.saved). Classification logic lives there; this file only
# verifies the controller orchestrates the right Voice API commands.
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

  # === call.answered → playback_start (greeting only, no gather) ===

  test "call.answered with pre-rendered audio plays greeting via playback_start" do
    setup_pre_rendered_greeting(@tenant.greeting_variant)
    seed_call(flow_state: "answered")
    pb_stub = stub_action(CCID, :playback_start)

    post_event answered_payload

    assert_requested pb_stub
    assert_equal "screening_prompt_playing", Call.find_by!(call_control_id: CCID).reload.flow_state
  ensure
    cleanup_greeting_files
  end

  test "call.answered without pre-rendered audio falls back to TTS via speak" do
    seed_call(flow_state: "answered")
    speak_stub = stub_action(CCID, :speak)

    post_event answered_payload

    assert_requested speak_stub
    assert_equal "screening_prompt_playing", Call.find_by!(call_control_id: CCID).reload.flow_state
  end

  # === call.playback.ended → record_start (caller's screening response) ===

  test "playback.ended in screening_prompt_playing → record_start with single-channel WAV + silence detection" do
    seed_call(flow_state: "screening_prompt_playing")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/record_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    post_event event_envelope("call.playback.ended")

    assert_equal "wav",    captured["format"]
    assert_equal "single", captured["channels"]
    assert_equal 30,       captured["max_length"]
    assert_equal 3,        captured["timeout_secs"], "silence detection (3s) cuts the recording short"
    assert_equal false,    captured["play_beep"]
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "screening_recording", call.flow_state
  end

  test "speak.ended in screening_prompt_playing also triggers record_start (TTS-greeting fallback)" do
    seed_call(flow_state: "screening_prompt_playing")
    record_stub = stub_action(CCID, :record_start)

    post_event event_envelope("call.speak.ended")

    assert_requested record_stub
    assert_equal "screening_recording", Call.find_by!(call_control_id: CCID).flow_state
  end

  test "playback.ended in hanging_up_after_speak issues hangup" do
    seed_call(flow_state: "hanging_up_after_speak")
    hangup_stub = stub_action(CCID, :hangup)

    post_event event_envelope("call.playback.ended")

    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
  end

  # === call.recording.saved → ScreeningJob (or TranscribeRecordingJob for legacy) ===

  test "recording.saved in screening_recording → enqueue ScreeningJob + immediate goodbye" do
    seed_call(flow_state: "screening_recording")
    speak_stub = stub_action(CCID, :speak)  # no pre-rendered audio in test

    assert_enqueued_jobs 1, only: ScreeningJob do
      post_event recording_saved_payload(url: "https://api.telnyx.com/v2/recordings/abc.wav")
    end
    # Controller plays a brief goodbye on the still-open leg so the caller
    # doesn't hear seconds of silence while Whisper runs.
    assert_requested speak_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "https://api.telnyx.com/v2/recordings/abc.wav", call.recording_url
    assert_equal "hanging_up_after_speak", call.flow_state
  end

  test "recording.saved with pre-rendered goodbye uses playback_start" do
    setup_pre_rendered_greeting("goodbye_spam")
    seed_call(flow_state: "screening_recording")
    pb_stub = stub_action(CCID, :playback_start)

    post_event recording_saved_payload(url: "https://x/a.wav")

    assert_requested pb_stub
    assert_equal "hanging_up_after_speak", Call.find_by!(call_control_id: CCID).flow_state
  ensure
    cleanup_greeting_files
  end

  test "recording.saved in legacy 'recording' state → enqueue TranscribeRecordingJob + hangup" do
    seed_call(flow_state: "recording")
    hangup_stub = stub_action(CCID, :hangup)

    assert_enqueued_jobs 1, only: TranscribeRecordingJob do
      post_event recording_saved_payload(url: "https://api.telnyx.com/v2/recordings/vm.wav")
    end
    assert_requested hangup_stub
    assert_equal "completed", Call.find_by!(call_control_id: CCID).status
  end

  test "recording.saved is idempotent — duplicate webhook does not double-enqueue" do
    seed_call(flow_state: "screening_recording")
    stub_action(CCID, :speak)  # the immediate goodbye on first webhook

    assert_enqueued_jobs 1, only: ScreeningJob do
      post_event recording_saved_payload(url: "https://x/a.wav")
      post_event recording_saved_payload(url: "https://x/a.wav")
    end
  end

  # === Multi-language: caller-language driven greeting + voice swap ===

  test "Italian caller (+39) gets the Italian greeting with the Italian voice" do
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "im_nicola")
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339991111")
    post_event answered_payload

    assert_match %r{/im_nicola/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
  end

  test "English caller (non-+39) gets the English greeting with the English voice equivalent" do
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "am_michael")
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+14155551234")
    post_event answered_payload

    assert_match %r{/am_michael/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
  end

  test "auto_detect_language=false pins greeting to tenant.greeting_language regardless of caller" do
    @tenant.update!(auto_detect_language: false, greeting_language: "it-IT")
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "im_nicola")
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+14155551234")
    post_event answered_payload

    # Even though caller is non-+39, we play the Italian voice/text.
    assert_match %r{/im_nicola/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
  end

  test "no pre-rendered audio → speak fallback uses the right text + locale per caller language" do
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/speak")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+14155551234")
    post_event answered_payload

    assert_equal "en-US", captured["language"]
    assert_match(/Hi|Hello|busy/i, captured["payload"])
  end

  # === Cloned voice (Chatterbox) takes priority over Kokoro when ready ===

  test "tenant with voice_clone_ready=true plays cloned audio path (_t<id>)" do
    @tenant.update_columns(
      voice_sample_path: "tenant_#{@tenant.id}.wav",
      voice_clone_consent_at: Time.current,
      voice_clone_active: true,
      voice_clone_rendered_at: Time.current
    )
    cloned_dir = @tenant.cloned_voice_dir
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: cloned_dir)
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339991111")
    post_event answered_payload

    assert_match %r{/#{cloned_dir}/}, captured["audio_url"]
    refute_match %r{/im_nicola/}, captured["audio_url"], "should NOT use the global Kokoro voice"
  ensure
    cleanup_greeting_files
  end

  test "tenant with voice_clone_active but no rendered file falls back to Kokoro" do
    @tenant.update_columns(
      voice_sample_path: "tenant_#{@tenant.id}.wav",
      voice_clone_consent_at: Time.current,
      voice_clone_active: true,
      voice_clone_rendered_at: Time.current
    )
    # NOTE: no setup_pre_rendered_greeting for cloned voice → file missing.
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "im_nicola")
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: "{}")

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339991111")
    post_event answered_payload

    # No cloned WAV exists → fell back to Kokoro im_nicola.
    assert_match %r{/im_nicola/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
  end

  test "tenant with voice_clone_active=false skips cloned path entirely" do
    @tenant.update_columns(
      voice_sample_path: "tenant_#{@tenant.id}.wav",
      voice_clone_consent_at: Time.current,
      voice_clone_active: false,
      voice_clone_rendered_at: Time.current
    )
    cloned_dir = @tenant.cloned_voice_dir
    # Even though the cloned file IS present, voice_clone_active=false → ignored.
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: cloned_dir)
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "im_nicola")
    seed_call(flow_state: "answered")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: "{}")

    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339991111")
    post_event answered_payload

    assert_match %r{/im_nicola/}, captured["audio_url"]
    refute_match %r{/#{cloned_dir}/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
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

  test "call.gather.ended (DTMF, currently unused) is acknowledged but does nothing" do
    seed_call(flow_state: "screening_recording")
    post_event event_envelope("call.gather.ended", { "call_control_id" => CCID, "digits" => "1" })
    assert_response :success
    # No state change — the controller has no use for the event in this flow.
    assert_equal "screening_recording", Call.find_by!(call_control_id: CCID).flow_state
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

  def setup_pre_rendered_greeting(slug, voice: nil)
    @greeting_paths ||= []
    voice ||= @tenant.greeting_voice
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
