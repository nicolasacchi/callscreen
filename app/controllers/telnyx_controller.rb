class TelnyxController < ApplicationController
  # Telnyx Voice API delivers JSON webhooks describing call events.
  # We persist a per-Call FSM (`flow_state`) and dispatch on
  # `data.event_type`. Outbound state changes are issued through the
  # CallControlClient. All commands are best-effort — we always return
  # 200 to Telnyx to acknowledge the webhook; recovery uses subsequent
  # events (call.hangup will fire when a leg drops, etc).
  #
  # Routes (config/routes.rb):
  #   POST /telnyx/voice    — single endpoint for ALL Voice API events
  #
  # Tenant resolution order, applied on `call.initiated`:
  #   1. Tenant.find_by(dedicated_number: payload[:to])
  #   2. Tenant.find_by(mobile_number: SipHeadersParser.original_called_number(...))
  #   3. Tenant.default (fallback; call is flagged unattributed)

  CALL_CONTROL_ID_FORMAT = /\A[A-Za-z0-9_:=\-]{1,256}\z/

  skip_before_action :verify_authenticity_token
  before_action :verify_telnyx_request

  # Single dispatcher route — accepts every Voice API event. Legacy
  # TeXML routes (/telnyx/voice, /telnyx/screen, /telnyx/clarify,
  # /telnyx/recording, /telnyx/status) all alias to here so a deploy that
  # half-rolls-back to TeXML doesn't 404.
  def voice
    payload = request_payload
    event   = payload.dig("data", "event_type")
    case event
    when "call.initiated"          then handle_initiated(payload)
    when "call.answered"           then handle_answered(payload)
    when "call.gather.ended"       then handle_gather_ended(payload)
    when "call.recording.saved"    then handle_recording_saved(payload)
    when "call.playback.ended", "call.speak.ended"
                                   then handle_playback_or_speak_ended(payload)
    when "call.hangup"             then handle_hangup(payload)
    else
      Rails.logger.info("TelnyxController: ignoring event_type=#{event.inspect}")
    end
    head :ok
  rescue StandardError => e
    Rails.logger.error("TelnyxController error: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    Sentry.capture_exception(e) if defined?(Sentry)
    head :ok
  end

  # Aliases — all five legacy routes funnel into the same dispatcher.
  alias_method :screen,    :voice
  alias_method :clarify,   :voice
  alias_method :recording, :voice
  alias_method :status,    :voice

  private

  # === Event handlers ===

  def handle_initiated(payload)
    p   = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"].to_s
    return unless ccid.match?(CALL_CONTROL_ID_FORMAT)

    from = PhoneNumberNormalizer.normalize(p["from"])
    to   = p["to"].to_s
    sip_headers = p["sip_headers"]

    tenant = resolve_tenant(to: to, sip_headers: sip_headers)

    external = RailsdavContactsClient.lookup(from, username: tenant.railsdav_username)

    contact = tenant.contacts.find_or_initialize_by(phone: from)
    contact.last_called_at = Time.current
    contact.name = external.name if external.matched? && contact.name.blank? && external.name.present?
    contact.save!

    call_attrs = {
      tenant: tenant,
      call_sid: ccid,
      call_control_id: ccid,
      from_number: from,
      to_number: to,
      status: :initiated,
      flow_state: "initiated",
      contact: contact,
      unattributed: tenant_unattributed?(tenant, to: to, sip_headers: sip_headers)
    }

    # Idempotent: if Telnyx retries call.initiated we should not duplicate.
    call = Call.find_or_initialize_by(call_control_id: ccid)
    call.assign_attributes(call_attrs) if call.new_record?
    call.save!

    # === Apply policy in priority order ===

    # 0. Per-caller rate limit (within 24h). Whitelisted callers and
    # railsdav-allowed callers are exempt from this gate so a known good
    # caller never gets blocked by a high call volume.
    if rate_limit_exceeded?(contact, tenant: tenant, external: external)
      limit = tenant.max_calls_per_caller_per_day || 10
      call.update!(
        status: :spam,
        flow_state: "done",
        ai_classification: {
          "classification" => "spam",
          "confidence" => 1.0,
          "reason" => "Rate limited (more than #{limit} calls in 24h)"
        }
      )
      NotifyJob.perform_later(call.id)
      cc_client.reject(ccid)
      return
    end

    # 1. Railsdav (centralized contacts) policy
    if external.matched?
      case external.policy
      when "block"
        call.update!(
          status: :spam,
          flow_state: "done",
          ai_classification: {
            "classification" => "spam",
            "confidence" => 1.0,
            "reason" => "Railsdav policy: block (#{external.addressbook})"
          }
        )
        NotifyJob.perform_later(call.id)
        cc_client.reject(ccid)
        return
      when "allow"
        call.update!(status: :legit, flow_state: "transfer_dialing")
        forward_or_record(call, tenant)
        return
      end
    end

    # 2. Local blacklist (operator override)
    if contact.blacklisted?
      call.update!(status: :spam, flow_state: "done")
      cc_client.reject(ccid)
      return
    end

    # 3. Local whitelist (operator override)
    if contact.whitelisted?
      call.update!(status: :legit, flow_state: "transfer_dialing")
      forward_or_record(call, tenant)
      return
    end

    # 4. Per-tenant rules (prefix/regex)
    rule_match = tenant.rules.active.find { |r| r.matches_number?(from) }
    if rule_match
      rule_match.increment!(:hit_count)
      if rule_match.action_block?
        call.update!(status: :spam, flow_state: "done")
        NotifyJob.perform_later(call.id)
        cc_client.reject(ccid)
        return
      elsif rule_match.action_allow?
        call.update!(status: :legit, flow_state: "transfer_dialing")
        forward_or_record(call, tenant)
        return
      end
    end

    # 5. Default — answer and proceed to greeting
    call.update!(status: :screening, flow_state: "answered")
    cc_client.answer(ccid)
  end

  def handle_answered(payload)
    p   = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    case call.flow_state
    when "answered"
      # Greeting + first gather
      call.update!(flow_state: "awaiting_speech")
      issue_greeting_gather(call)
    when "transfer_dialing"
      # Allow path actually triggers transfer immediately on initiated; nothing to do here.
    end
  end

  def handle_gather_ended(payload)
    p   = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    transcript = p.dig("transcription", "transcript").to_s
    # When the gather ends because the caller hung up mid-prompt, Telnyx
    # sets payload.status="call_hangup" and the leg is already dead. Any
    # further command (playback, speak, hangup) returns 422 "Call has
    # already ended". We must short-circuit and not issue follow-up audio.
    gather_status = p["status"].to_s

    case call.flow_state
    when "awaiting_speech"
      classify_first_pass(call, transcript, gather_status: gather_status)
    when "clarification_awaiting_speech"
      classify_clarification_pass(call, transcript, gather_status: gather_status)
    end
  end

  def handle_recording_saved(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    url  = p["recording_urls"]&.values&.first || p["recording_url"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    if call.recording_url.blank?
      call.update!(
        recording_url: url,
        duration_seconds: p["duration_seconds"].to_i,
        status: :completed,
        flow_state: "done"
      )
      TranscribeRecordingJob.perform_later(call.id)
    end
    cc_client.hangup(ccid)
  end

  def handle_playback_or_speak_ended(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    if call.flow_state == "hanging_up_after_speak"
      call.update!(flow_state: "done")
      cc_client.hangup(ccid)
    end
  end

  def handle_hangup(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    call.update!(flow_state: "done") unless call.flow_state == "done"
    if call.contact.present?
      call.contact.update!(last_called_at: Time.current)
    end
  end

  # === Tenant resolution ===

  def resolve_tenant(to:, sip_headers:)
    by_dedicated = Tenant.find_by(dedicated_number: to.to_s)
    return by_dedicated if by_dedicated

    if (orig = SipHeadersParser.original_called_number(sip_headers))
      by_mobile = Tenant.find_by(mobile_number: orig)
      return by_mobile if by_mobile
    end

    Tenant.default
  end

  def tenant_unattributed?(tenant, to:, sip_headers:)
    # If we matched by dedicated_number or by History-Info that's an
    # attributed call. Only the fallback to default counts as unattributed.
    !(tenant.dedicated_number.present? && tenant.dedicated_number == to.to_s) &&
      SipHeadersParser.original_called_number(sip_headers) != tenant.mobile_number
  end

  # === Classification ===

  def classify_first_pass(call, transcript, gather_status: nil)
    tenant = call.tenant
    call.update!(screening_transcript: transcript)

    if transcript.blank?
      mark_unknown_and_followup(call, gather_status: gather_status)
      return
    end

    # Keyword rules
    keyword_rule = tenant.rules.active.keyword.find { |r| r.matches_transcript?(transcript) }
    if keyword_rule
      keyword_rule.increment!(:hit_count)
      if keyword_rule.action_block?
        call.update!(
          ai_classification: { "classification" => "spam", "confidence" => 1.0, "reason" => "Keyword rule: #{keyword_rule.value}" }
        )
        finish_with_spam(call, phrase: "goodbye_spam")
        return
      end
    end

    sensitivity = tenant.spam_sensitivity || Setting.get("spam_sensitivity").to_f
    result = SpamClassifier.new(transcript, from_number: call.from_number, sensitivity: sensitivity).classify
    call.update!(ai_classification: result)

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        finish_with_spam(call, phrase: "goodbye_spam")
      else
        ask_clarification(call)
      end
    when "legit"
      call.update!(status: :legit)
      start_voicemail(call)
    else
      ask_clarification(call)
    end
  end

  def classify_clarification_pass(call, transcript, gather_status: nil)
    tenant = call.tenant
    combined = "#{call.screening_transcript}\n[Clarification]: #{transcript}".strip
    call.update!(screening_transcript: combined)

    if transcript.blank?
      mark_unknown_and_followup(call, gather_status: gather_status)
      return
    end

    sensitivity = tenant.spam_sensitivity || Setting.get("spam_sensitivity").to_f
    result = SpamClassifier.new(combined, from_number: call.from_number, sensitivity: sensitivity).classify
    call.update!(ai_classification: result)

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        finish_with_spam(call, phrase: "goodbye_spam")
      else
        call.update!(status: :uncertain)
        start_voicemail(call)
      end
    when "legit"
      call.update!(status: :legit)
      start_voicemail(call)
    else
      call.update!(status: :uncertain)
      start_voicemail(call)
    end
  end

  # === Outbound command shortcuts ===

  def issue_greeting_gather(call)
    tenant = call.tenant
    audio  = greeting_audio_url_for(tenant, slug: tenant.greeting_variant)

    if audio
      cc_client.gather_using_audio(call.call_control_id,
        audio_url: audio,
        language:  tenant.greeting_language,
        transcription_engine: Setting.get("transcription_engine"),
        total_timeout_secs: 30
      )
    else
      cc_client.gather_using_speak(call.call_control_id,
        payload:  GreetingCatalog.text_for(tenant.greeting_variant) || tenant.greeting_text || Setting.get("greeting_text"),
        voice:    "alice",
        language: tenant.greeting_language,
        transcription_engine: Setting.get("transcription_engine"),
        total_timeout_secs: 30
      )
    end
  end

  def ask_clarification(call)
    tenant = call.tenant
    call.update!(status: :uncertain, flow_state: "clarification_awaiting_speech")
    audio = greeting_audio_url_for(tenant, slug: "clarify")
    if audio
      cc_client.gather_using_audio(call.call_control_id,
        audio_url: audio, language: tenant.greeting_language,
        transcription_engine: Setting.get("transcription_engine"))
    else
      cc_client.gather_using_speak(call.call_control_id,
        payload: GreetingCatalog::SYSTEM_PHRASES["clarify"],
        voice: "alice", language: tenant.greeting_language,
        transcription_engine: Setting.get("transcription_engine"))
    end
  end

  def start_voicemail(call)
    tenant = call.tenant
    call.update!(flow_state: "voicemail_prompt_playing", status: call.status)
    audio = greeting_audio_url_for(tenant, slug: "voicemail_prompt")
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: GreetingCatalog::SYSTEM_PHRASES["voicemail_prompt"],
        voice: "alice", language: tenant.greeting_language)
    end
    cc_client.record_start(call.call_control_id,
      max_length: tenant.max_recording_seconds || 120,
      play_beep: true)
    call.update!(flow_state: "recording", status: :recording)
  end

  # Empty transcript path. The caller didn't say anything during the
  # gather. Two scenarios:
  #
  #   gather_status == "call_hangup": the caller already hung up — the
  #   leg is dead. Don't try to play any goodbye (Telnyx returns 422
  #   "Call has already ended"). Just mark the call unknown and notify
  #   the operator. The follow-up call.hangup event will finalize.
  #
  #   gather_status == "valid"/"timeout": the call is still live. Send
  #   the caller to voicemail rather than hanging up — many people just
  #   need a beat to gather their thoughts after the prompt. Status is
  #   :unknown (not :spam) since we have no signal at all about intent.
  def mark_unknown_and_followup(call, gather_status: nil)
    if gather_status == "call_hangup"
      call.update!(status: :unknown, flow_state: "done")
      NotifyJob.perform_later(call.id)
      return
    end

    call.update!(status: :unknown)
    start_voicemail(call)
  end

  def finish_with_spam(call, phrase:)
    tenant = call.tenant
    call.update!(status: :spam, flow_state: "hanging_up_after_speak")
    NotifyJob.perform_later(call.id)
    auto_blacklist_if_pattern_match(call)
    audio = greeting_audio_url_for(tenant, slug: phrase)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: GreetingCatalog::SYSTEM_PHRASES[phrase] || "Arrivederci.",
        voice: "alice", language: tenant.greeting_language)
    end
  end

  # === Abuse defenses ===

  def rate_limit_exceeded?(contact, tenant:, external:)
    # Whitelisted contacts (operator override) and railsdav-allowed
    # contacts are exempt — they're known-good callers.
    return false if contact.whitelisted?
    return false if external.matched? && external.policy == "allow"
    limit = (tenant.max_calls_per_caller_per_day || 10).to_i
    return false if limit <= 0
    contact.recent_calls_count(within: 24.hours) > limit
  end

  def auto_blacklist_if_pattern_match(call)
    tenant  = call.tenant
    contact = call.contact
    return unless contact
    return if contact.blacklisted?  # already blocked
    return if contact.whitelisted?  # operator-trusted

    threshold = (tenant.auto_blacklist_threshold || 3).to_i
    window    = (tenant.auto_blacklist_window_days || 7).to_i
    return if threshold <= 0 || window <= 0

    count = contact.recent_spam_count(within: window.days)
    return if count < threshold

    contact.update!(blacklisted: true)
    AuditLog.create!(
      actor: nil,
      tenant: tenant,
      action: "auto_blacklist",
      subject_type: "Contact",
      subject_id: contact.id,
      metadata: {
        from: call.from_number,
        spam_count: count,
        window_days: window,
        threshold: threshold
      }
    )
  end

  def forward_or_record(call, tenant)
    target = tenant.forward_back_number.presence || ENV["FORWARD_NUMBER"]
    if target.present?
      call.update!(flow_state: "transfer_dialing")
      cc_client.transfer(call.call_control_id, to: target, timeout_secs: 15)
    else
      start_voicemail(call)
    end
  end

  def greeting_audio_url_for(tenant, slug:)
    return nil unless slug
    return nil unless GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
    voice = tenant.greeting_voice
    tone  = tenant.greeting_tone
    return nil unless Setting::ALLOWED_VOICES.include?(voice.to_s)
    return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)
    return nil unless GreetingsStorage.path_for(slug, voice, tone).exist?
    "#{ENV.fetch('APP_DOMAIN', 'https://phone.example.com')}/greetings/#{slug}/#{voice}/#{tone}.wav"
  end

  def cc_client
    @cc_client ||= CallControlClient.new
  end

  # === Webhook authentication ===

  def request_payload
    request.body.rewind
    raw = request.body.read
    return {} if raw.empty?
    JSON.parse(raw)
  rescue JSON::ParserError
    {}
  end

  def verify_telnyx_request
    return if signature_valid?
    return if fallback_token_valid?
    head :unauthorized
  end

  def signature_valid?
    sig = request.headers["Telnyx-Signature-Ed25519"]
    ts  = request.headers["Telnyx-Timestamp"]
    return false if sig.blank? || ts.blank?

    request.body.rewind
    payload = request.body.read

    TelnyxSignatureVerifier.new.verify(payload: payload, signature: sig, timestamp: ts)
  end

  def fallback_token_valid?
    return false unless fallback_enabled?
    expected = ENV.fetch("WEBHOOK_TOKEN", "")
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)
  end

  def fallback_enabled?
    ENV["WEBHOOK_TOKEN"].present? && ENV["WEBHOOK_TOKEN_FALLBACK"] != "0"
  end
end
