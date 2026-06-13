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

  test "synthetic token (?synthetic_token=) authenticates when SYNTHETIC_WEBHOOK_TOKEN is set" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-test-token"
    ENV["WEBHOOK_TOKEN_FALLBACK"]  = "0"  # ensure fallback is OFF
    post telnyx_voice_url(synthetic_token: "syn-test-token"),
         params: event_envelope("call.unknown.foo").to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :success
  ensure
    ENV.delete("SYNTHETIC_WEBHOOK_TOKEN")
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "1"
  end

  test "synthetic token rejected when env var is unset" do
    ENV.delete("SYNTHETIC_WEBHOOK_TOKEN")
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "0"
    post telnyx_voice_url(synthetic_token: "anything"),
         params: event_envelope("call.unknown.foo").to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  ensure
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "1"
  end

  test "synthetic token mismatch is rejected" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-test-token"
    ENV["WEBHOOK_TOKEN_FALLBACK"]  = "0"
    post telnyx_voice_url(synthetic_token: "wrong-token"),
         params: event_envelope("call.unknown.foo").to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  ensure
    ENV.delete("SYNTHETIC_WEBHOOK_TOKEN")
    ENV["WEBHOOK_TOKEN_FALLBACK"] = "1"
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

  # === Spam-DB (cross-tenant) gate ===

  test "spam_global match in default silent mode → reject + spam_db_global source" do
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "screen",
                    name: "Robocall", addressbook: "Public",
                    spam_global: true)
      reject_stub = stub_action(CCID, :reject)
      answer_stub = stub_action(CCID, :answer)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested reject_stub
      assert_not_requested answer_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "spam", call.status
      assert_equal "spam_db_global", call.ai_classification_source
      assert_equal "done", call.flow_state
    end
  end

  test "spam_global hits even when railsdav has no contact (match: false + spam_global: true)" do
    with_railsdav_env do
      # Number not in any address book, but in the global spam DB —
      # the typical spam-DB hit shape.
      stub_request(:get, "http://railsdav.test:3000/api/contact_lookup")
        .with(query: { phone: CALLER_FROM, username: "default" })
        .to_return(
          status: 200,
          body: {
            match: false,
            spam_global: true,
            spam_metadata: { source: "feed:tellows", report_count: 12, first_reported_at: "2026-03-01T00:00:00Z" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      reject_stub = stub_action(CCID, :reject)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested reject_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "spam_db_global", call.ai_classification_source
    end
  end

  test "spam_global match in polite_disclose mode → answer + flow_state=spam_disclose_playing" do
    @tenant.update!(spam_response_mode: "polite_disclose")
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "screen",
                    name: "Robocall", addressbook: "Public",
                    spam_global: true)
      answer_stub = stub_action(CCID, :answer)
      reject_stub = stub_action(CCID, :reject)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested answer_stub
      assert_not_requested reject_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "spam_disclose_playing", call.flow_state
      assert_equal "spam", call.status
    end
  end

  test "spam_global match in time_waster mode → answer + flow_state=troll_playing" do
    @tenant.update!(spam_response_mode: "time_waster")
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "screen",
                    name: "Robocall", addressbook: "Public",
                    spam_global: true)
      answer_stub = stub_action(CCID, :answer)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested answer_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "troll_playing", call.flow_state
      assert_equal 0, call.troll_segment_index
    end
  end

  test "railsdav policy=allow OVERRIDES spam_global=true (operator allowlist wins)" do
    @tenant.update!(forward_back_number: "+393990000001")
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "allow",
                    name: "Mama", addressbook: "Family",
                    spam_global: true)
      transfer_stub = stub_action(CCID, :transfer)
      reject_stub   = stub_action(CCID, :reject)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested transfer_stub
      assert_not_requested reject_stub
      call = Call.find_by!(call_control_id: CCID)
      assert_equal "legit", call.status
    end
  end

  test "local whitelist OVERRIDES spam_global=true (operator allowlist wins)" do
    @tenant.update!(forward_back_number: "+393990000001")
    @tenant.contacts.create!(phone: CALLER_FROM, whitelisted: true)
    with_railsdav_env do
      stub_railsdav(CALLER_FROM, username: "default", policy: "screen",
                    name: "Friend", addressbook: "Public",
                    spam_global: true)
      transfer_stub = stub_action(CCID, :transfer)

      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

      assert_requested transfer_stub
      assert_equal "legit", Call.find_by!(call_control_id: CCID).status
    end
  end

  test "rate-limit ALWAYS silent regardless of tenant.spam_response_mode (force_silent)" do
    @tenant.update!(spam_response_mode: "time_waster", max_calls_per_caller_per_day: 1)
    contact = @tenant.contacts.create!(phone: CALLER_FROM)
    # Two prior calls in the rate-limit window — third one trips the limiter.
    2.times { @tenant.calls.create!(contact: contact, from_number: CALLER_FROM, status: :spam) }
    reject_stub = stub_action(CCID, :reject)
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_requested reject_stub
    assert_not_requested answer_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "rate_limit", call.ai_classification_source
    assert_equal "done", call.flow_state
  end

  test "rule action_block ALWAYS silent regardless of tenant.spam_response_mode (force_silent)" do
    @tenant.update!(spam_response_mode: "time_waster")
    @tenant.rules.create!(rule_type: :prefix, action: :block, value: "+39333", active: true)
    reject_stub = stub_action(CCID, :reject)
    answer_stub = stub_action(CCID, :answer)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_requested reject_stub
    assert_not_requested answer_stub
    assert_equal "rule", Call.find_by!(call_control_id: CCID).ai_classification_source
  end

  test "blacklist preserves silent-no-notify (no NotifyJob enqueued)" do
    @tenant.contacts.create!(phone: CALLER_FROM, blacklisted: true)
    stub_action(CCID, :reject)

    assert_no_enqueued_jobs only: NotifyJob do
      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
    end
  end

  test "call.answered in spam_disclose_playing → playback_start of spam_disclose phrase" do
    setup_pre_rendered_greeting("spam_disclose")
    seed_call(flow_state: "spam_disclose_playing", status: :spam)
    pb_stub = stub_action(CCID, :playback_start)

    post_event answered_payload

    assert_requested pb_stub
  ensure
    cleanup_greeting_files
  end

  test "playback.ended in spam_disclose_playing → hangup" do
    seed_call(flow_state: "spam_disclose_playing", status: :spam)
    hangup_stub = stub_action(CCID, :hangup)

    post_event event_envelope("call.playback.ended")

    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
  end

  test "playback.ended in troll_playing advances segment index" do
    seed_call(flow_state: "troll_playing", status: :spam, answered_at: 5.seconds.ago)
    setup_pre_rendered_greeting("troll_hold_loop")
    pb_stub = stub_action(CCID, :playback_start)

    post_event event_envelope("call.playback.ended")

    assert_requested pb_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal 1, call.troll_segment_index
    assert_equal "troll_playing", call.flow_state
  ensure
    cleanup_greeting_files
  end

  test "troll_playing hangs up when spam_troll_max_seconds elapsed" do
    @tenant.update!(spam_troll_max_seconds: 30)
    seed_call(flow_state: "troll_playing", status: :spam, answered_at: 60.seconds.ago)
    hangup_stub = stub_action(CCID, :hangup)

    post_event event_envelope("call.playback.ended")

    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
  end

  test "troll_playing hangs up at end of segment sequence" do
    seed_call(flow_state: "troll_playing", status: :spam,
              answered_at: 5.seconds.ago,
              troll_segment_index: TelnyxController::TROLL_SEGMENTS.size - 1)
    hangup_stub = stub_action(CCID, :hangup)

    post_event event_envelope("call.playback.ended")

    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
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
    # Clear greeting_voice so audio_url_for_voice short-circuits on
    # `voice.blank?` regardless of what WAVs exist on the host volume
    # under storage/greetings/. (Without this guard the test is order-
    # dependent: a previous test's setup_pre_rendered_greeting +
    # cleanup_greeting_files cycle nukes the real WAV, which we'd
    # otherwise pick up.)
    @tenant.update_columns(greeting_voice: nil)
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

  test "playback.ended honours the tenant's screening_speech_timeout setting" do
    @tenant.update!(screening_speech_timeout: "7")
    seed_call(flow_state: "screening_prompt_playing")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/record_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    post_event event_envelope("call.playback.ended")

    assert_equal 7, captured["timeout_secs"], "per-tenant speech timeout should drive silence detection"
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

  test "recording.saved with no URL is a no-op; a later delivery with the URL still wins" do
    # REL-3: a nil-URL delivery is ignored (nothing to process), so the later
    # delivery that carries the real URL still advances + enqueues exactly once,
    # and the URL is persisted (not lost).
    seed_call(flow_state: "screening_recording")
    stub_action(CCID, :speak)

    assert_enqueued_jobs 1, only: ScreeningJob do
      post_event recording_saved_payload(url: nil)
      post_event recording_saved_payload(url: "https://x/late.wav")
    end
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "hanging_up_after_speak", call.flow_state
    assert_equal "https://x/late.wav", call.recording_url, "the real URL must be persisted, not lost"
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

  # === Round-robin voice rotation ===

  test "voice rotation cursor advances exactly once per call (greeting + goodbye both fire)" do
    @tenant.update!(
      voice_rotation_enabled: true,
      voice_rotation_voices:  "if_sara,im_nicola",
      voice_rotation_index:   0,
      auto_blacklist_threshold: nil  # don't trip during the recording branch
    )
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "if_sara")
    setup_pre_rendered_greeting("goodbye_spam",            voice: "if_sara")
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start").to_return(status: 200, body: "{}")
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/record_start").to_return(status: 200, body: "{}")
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/hangup").to_return(status: 200, body: "{}")

    # call.answered → play_greeting → cursor advances
    seed_call(flow_state: "answered")
    post_event answered_payload
    assert_equal 1, @tenant.reload.voice_rotation_index, "greeting should advance cursor by 1"

    # call.recording.saved → play_goodbye (in screening_recording flow_state)
    Call.find_by!(call_control_id: CCID).update!(flow_state: "screening_recording", recording_url: nil)
    post_event recording_saved_payload(url: "https://api.telnyx.com/v2/recordings/x.wav")

    # Cursor should NOT advance again — same call, voice cached on Call#selected_voice.
    assert_equal 1, @tenant.reload.voice_rotation_index, "goodbye should reuse picked voice; cursor stays at 1"

    call = Call.find_by!(call_control_id: CCID)
    assert_equal "if_sara", call.selected_voice
  ensure
    cleanup_greeting_files
  end

  test "voice_rotation_enabled cycles through voices across consecutive calls" do
    @tenant.update!(
      voice_rotation_enabled: true,
      voice_rotation_voices: "if_sara,im_nicola",
      voice_rotation_index: 0
    )
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "if_sara")
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "im_nicola")

    captured_urls = []
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured_urls << JSON.parse(req.body)["audio_url"]; true }
      .to_return(status: 200, body: '{"data":{"result":"ok"}}')

    # First call → if_sara
    seed_call(flow_state: "answered")
    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339991111")
    post_event answered_payload
    Call.find_by!(call_control_id: CCID).destroy

    # Second call → im_nicola
    seed_call(flow_state: "answered")
    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339992222")
    post_event answered_payload
    Call.find_by!(call_control_id: CCID).destroy

    # Third call → if_sara (cycle wraps)
    seed_call(flow_state: "answered")
    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339993333")
    post_event answered_payload

    assert_equal 3, captured_urls.size
    assert_match %r{/if_sara/},   captured_urls[0]
    assert_match %r{/im_nicola/}, captured_urls[1]
    assert_match %r{/if_sara/},   captured_urls[2]
    assert_equal 3, @tenant.reload.voice_rotation_index
  ensure
    cleanup_greeting_files
  end

  test "voice_rotation_enabled with English caller swaps Italian voices to English" do
    @tenant.update!(
      voice_rotation_enabled: true,
      voice_rotation_voices: "if_sara",
      voice_rotation_index: 0
    )
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "af_heart")
    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: "{}")

    seed_call(flow_state: "answered")
    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+14155551234")
    post_event answered_payload

    assert_match %r{/af_heart/}, captured["audio_url"], "if_sara → af_heart for English caller"
  ensure
    cleanup_greeting_files
  end

  test "voice_rotation can include the cloned voice in the rotation list" do
    @tenant.update_columns(
      voice_sample_path: "tenant_#{@tenant.id}.wav",
      voice_clone_consent_at: Time.current,
      voice_clone_active: true,
      voice_clone_rendered_at: Time.current,
      voice_rotation_enabled: true,
      voice_rotation_voices: "#{@tenant.cloned_voice_dir},if_sara",
      voice_rotation_index: 0
    )
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: @tenant.cloned_voice_dir)
    setup_pre_rendered_greeting(@tenant.greeting_variant, voice: "if_sara")
    captured_urls = []
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured_urls << JSON.parse(req.body)["audio_url"]; true }
      .to_return(status: 200, body: "{}")

    2.times do
      seed_call(flow_state: "answered")
      @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339994444")
      post_event answered_payload
      Call.find_by!(call_control_id: CCID).destroy
    end

    assert_match %r{/#{@tenant.cloned_voice_dir}/}, captured_urls[0]
    assert_match %r{/if_sara/}, captured_urls[1]
  ensure
    cleanup_greeting_files
  end

  test "voice_rotation falls through to clone or default when rotated voice has no rendered file" do
    # Use a unique test-only slug so we control which voice variants
    # have real files on disk (the production storage volume contains
    # WAVs for every catalog slug × voice, which would otherwise let
    # if_sara succeed instead of falling through).
    test_slug = "fallthrough_only_im_nicola"
    Phrase.create!(tenant: @tenant, slug: test_slug, label: "X",
                   kind: "user", text_it: "x", text_en: "x",
                   render_status: "rendered", last_rendered_at: Time.current)
    @tenant.update!(
      greeting_variant: test_slug,
      voice_rotation_enabled: true,
      voice_rotation_voices: "if_sara,im_nicola",
      voice_rotation_index: 0
    )
    # Only im_nicola exists for this slug; if_sara doesn't.
    setup_pre_rendered_greeting(test_slug, voice: "im_nicola")

    captured = nil
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .with { |req| captured = JSON.parse(req.body); true }
      .to_return(status: 200, body: "{}")

    seed_call(flow_state: "answered")
    @tenant.calls.find_by!(call_control_id: CCID).update!(from_number: "+393339995555")
    post_event answered_payload

    # First rotation pick was if_sara (no file for test_slug) → fell
    # through → tenant.greeting_voice = im_nicola.
    assert_match %r{/im_nicola/}, captured["audio_url"]
  ensure
    cleanup_greeting_files
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

  test "call.hangup after call.answered captures billable_seconds and telnyx_cost_usd" do
    seed_call(flow_state: "answered", contact: contacts(:regular))
    # Pretend Telnyx answered the call 12 seconds ago.
    Call.find_by!(call_control_id: CCID).update!(answered_at: 12.seconds.ago)

    post_event event_envelope("call.hangup")

    call = Call.find_by!(call_control_id: CCID)
    assert call.hung_up_at.present?, "hung_up_at must be stamped on hangup"
    assert call.billable_seconds && call.billable_seconds >= 11
    expected = Pricing.telnyx_voice_usd(call.billable_seconds)
    assert_in_delta expected, call.telnyx_cost_usd.to_f, 1e-9
  end

  test "call.hangup with no answered_at bills $0 (rejected before answer)" do
    seed_call(flow_state: "done", contact: contacts(:regular))
    post_event event_envelope("call.hangup")
    call = Call.find_by!(call_control_id: CCID)
    assert call.hung_up_at.present?
    assert_nil call.billable_seconds
    assert_equal 0.0, call.telnyx_cost_usd.to_f
  end

  test "call.answered stamps answered_at" do
    seed_call(flow_state: "answered", contact: contacts(:regular))
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/playback_start")
      .to_return(status: 200, body: "{}")
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/speak")
      .to_return(status: 200, body: "{}")

    post_event answered_payload

    call = Call.find_by!(call_control_id: CCID)
    assert call.answered_at.present?, "answered_at must be stamped on call.answered"
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

  # === Malformed / partial payloads degrade gracefully (TEST-5) ===

  test "valid JSON without a data envelope is acknowledged (200) and creates nothing" do
    assert_no_difference -> { Call.count } do
      post_event({ "foo" => "bar" })
    end
    assert_response :success
  end

  test "call.initiated with missing from/to does not create a Call and still 200s" do
    assert_no_difference -> { Call.count } do
      post_event event_envelope("call.initiated", { "call_control_id" => "v3:malformed-init" })
    end
    assert_response :success
    assert_nil Call.find_by(call_control_id: "v3:malformed-init")
  end

  test "recording.saved for an unknown call is a no-op 200" do
    post_event event_envelope("call.recording.saved", { "call_control_id" => "v3:unknown-rec" })
    assert_response :success
  end

  test "unparseable body reaching the controller is acknowledged (200), not a 500" do
    # Content-Type text/plain so Rails' own JSON middleware doesn't 400 it
    # first; this exercises the controller's request_payload JSON.parse rescue.
    post telnyx_voice_url(token: @token), params: "<<not json>>",
         headers: { "Content-Type" => "text/plain" }
    assert_response :success
  end

  # === P0-1 / REL-2: a failing goodbye must never block classification ===

  test "recording.saved still enqueues ScreeningJob when the cosmetic goodbye raises" do
    seed_call(flow_state: "screening_recording")
    # Force play_goodbye to blow up (stands in for a SQLite busy error in
    # pick_voice_for_call! under contention) by making its first call raise.
    # The classification enqueue is the load-bearing work and must survive; we
    # must still ACK 200. (minitest/mock isn't bundled here, so swap the
    # singleton method directly.)
    original = LanguageResolver.method(:for)
    LanguageResolver.define_singleton_method(:for) { |_call| raise "boom" }
    begin
      assert_enqueued_jobs 1, only: ScreeningJob do
        post_event recording_saved_payload(url: "https://api.telnyx.com/v2/recordings/abc.wav")
      end
      assert_response :success
    ensure
      LanguageResolver.define_singleton_method(:for, original)
    end
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "hanging_up_after_speak", call.flow_state
    assert_equal "https://api.telnyx.com/v2/recordings/abc.wav", call.recording_url
  end

  # === P0-2 / REL-1: a failed transfer must fall back to voicemail ===

  test "failed transfer falls back to voicemail instead of stranding the caller in transfer_dialing" do
    @tenant.update!(forward_back_number: "+393990000001")
    @tenant.contacts.create!(phone: CALLER_FROM, whitelisted: true)
    # Telnyx rejects the transfer command (e.g. invalid destination → 422).
    failed_transfer = stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/transfer")
                        .to_return(status: 422, body: '{"errors":[{"detail":"bad"}]}',
                                   headers: { "Content-Type" => "application/json" })
    # Voicemail prompt plays via speak or playback_start depending on whether a
    # rendered WAV exists; record_start always fires once voicemail is reached.
    stub_action(CCID, :speak)
    stub_action(CCID, :playback_start)
    record_stub = stub_action(CCID, :record_start)

    post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))

    assert_requested failed_transfer
    # A failed transfer must fall through to voicemail capture, not strand the leg.
    assert_requested record_stub
    call = Call.find_by!(call_control_id: CCID)
    assert_equal "recording", call.flow_state, "must not be left stranded in transfer_dialing"
    assert_equal "recording", call.status
  end

  # === P1-7: the dispatcher always 200s, even when a handler raises ===

  test "a raising handler still returns 200 so Telnyx never replays a webhook storm" do
    # Make a collaborator deep in handle_initiated blow up; the top-level rescue
    # must still ACK 200 (a 5xx would make Telnyx re-deliver and replay the flow).
    original = RailsdavContactsClient.method(:lookup)
    RailsdavContactsClient.define_singleton_method(:lookup) { |*| raise "boom" }
    begin
      post_event initiated_payload(history_info: history_info_for(@tenant.mobile_number))
      assert_response :success
    ensure
      RailsdavContactsClient.define_singleton_method(:lookup, original)
    end
  end

  # === P1-4: call.bridged confirms a transfer connected ===

  test "call.bridged moves a connected transfer from transfer_dialing to bridged" do
    seed_call(flow_state: "transfer_dialing", status: :legit)
    post_event event_envelope("call.bridged", { "call_control_id" => CCID, "state" => "bridged" })
    assert_response :success
    assert_equal "bridged", Call.find_by!(call_control_id: CCID).flow_state
  end

  test "playback.ended with a non-completed status still advances the flow (logged, not stranded)" do
    seed_call(flow_state: "hanging_up_after_speak")
    hangup_stub = stub_action(CCID, :hangup)
    post_event event_envelope("call.playback.ended", { "call_control_id" => CCID, "status" => "failed" })
    assert_requested hangup_stub
    assert_equal "done", Call.find_by!(call_control_id: CCID).flow_state
  end

  private

  def seed_call(flow_state:, contact: nil, screening_transcript: nil, status: :screening,
                answered_at: nil, troll_segment_index: 0)
    @tenant.calls.create!(
      call_sid: CCID, call_control_id: CCID,
      from_number: CALLER_FROM, to_number: TENANT_TO,
      flow_state: flow_state, status: status,
      contact: contact || @tenant.contacts.find_or_create_by!(phone: CALLER_FROM),
      screening_transcript: screening_transcript,
      answered_at: answered_at,
      troll_segment_index: troll_segment_index
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

  def stub_railsdav(phone, username:, policy:, name:, addressbook:, spam_global: false, spam_metadata: nil)
    body = { match: true, name: name, policy: policy, addressbook: addressbook, contact_id: 1 }
    if spam_global
      body[:spam_global]   = true
      body[:spam_metadata] = spam_metadata || { source: "ntfy_report", report_count: 3, first_reported_at: "2026-04-01T12:00:00Z" }
    end
    stub_request(:get, "http://railsdav.test:3000/api/contact_lookup")
      .with(query: { phone: phone, username: username })
      .to_return(
        status: 200,
        body: body.to_json,
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
