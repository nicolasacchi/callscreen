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
  #
  # Screening flow (Voice API does NOT support transcription on
  # gather_using_audio — only DTMF — so we capture caller speech via
  # record_start and transcribe with Whisper post-hoc):
  #
  #   call.initiated → answer
  #   call.answered → playback_start(greeting)         state=screening_prompt_playing
  #   call.playback.ended → record_start(max_length)   state=screening_recording
  #   call.recording.saved → enqueue ScreeningJob      state=processing
  #   ScreeningJob → Whisper → SpamClassifier → finalize
  #   call.hangup → mark done

  CALL_CONTROL_ID_FORMAT = /\A[A-Za-z0-9_:=\-]{1,256}\z/
  SCREENING_RECORDING_MAX_SECS = 30
  # Stop recording after this many seconds of silence. Lets a caller who
  # said "Sono Mario, chiamo per la cena" finish + pause + get hung up
  # in ~8s instead of waiting the full max_length=30s timeout.
  SCREENING_SILENCE_TIMEOUT_SECS = 3

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
      # Play the greeting. Caller speech will be captured by the
      # follow-up record_start that fires on call.playback.ended.
      call.update!(flow_state: "screening_prompt_playing")
      play_greeting(call)
    when "transfer_dialing"
      # Allow path triggered transfer immediately on initiated; nothing to do.
    end
  end

  def handle_playback_or_speak_ended(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    case call.flow_state
    when "screening_prompt_playing"
      # Greeting finished — start recording the caller's speech.
      # timeout_secs cuts the recording short on a few seconds of
      # silence; max_length is the hard cap for very talkative callers.
      call.update!(flow_state: "screening_recording")
      cc_client.record_start(call.call_control_id,
        format: "wav",
        channels: "single",
        max_length: SCREENING_RECORDING_MAX_SECS,
        timeout_secs: SCREENING_SILENCE_TIMEOUT_SECS,
        play_beep: false,
        trim: "trim-silence")
    when "hanging_up_after_speak"
      call.update!(flow_state: "done")
      cc_client.hangup(ccid)
    end
  end

  def handle_recording_saved(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    url  = p["recording_urls"]&.values&.first || p["recording_url"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    # Idempotent: Telnyx fires recording.saved twice (one for the
    # action callback, one for the recordingStatusCallback). First
    # webhook wins; the rest are no-ops.
    return if call.recording_url.present?

    call.update!(
      recording_url: url,
      duration_seconds: p["duration_seconds"].to_i
    )

    case call.flow_state
    when "screening_recording"
      # Caller is still on the line — close their leg promptly so they
      # don't hear ~30 seconds of silence while Whisper + the LLM run.
      # Play a short "thanks, goodbye" and hangup on speak.ended (existing
      # hanging_up_after_speak branch). Classification continues async in
      # ScreeningJob, which writes status/transcript/ai_classification
      # without touching flow_state.
      call.update!(flow_state: "hanging_up_after_speak")
      play_goodbye(call, phrase: "goodbye_spam")
      ScreeningJob.perform_later(call.id)
    when "recording"
      # Legacy whitelisted-voicemail path (greeting + record without
      # screening, used when an allow-listed caller has no
      # forward_back_number set). Just transcribe + notify.
      call.update!(status: :completed, flow_state: "done")
      TranscribeRecordingJob.perform_later(call.id)
      cc_client.hangup(ccid)
    else
      Rails.logger.info("recording.saved in unexpected flow_state=#{call.flow_state}")
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

  # === Outbound command shortcuts ===

  # Short "thanks, goodbye" before hangup. Pre-rendered audio if available;
  # falls back to TTS via speak. The follow-up call.speak.ended OR
  # call.playback.ended (state=hanging_up_after_speak) issues the hangup.
  def play_goodbye(call, phrase:)
    tenant = call.tenant
    lang = caller_language(call)
    audio = greeting_audio_url_for(tenant, slug: phrase, language: lang)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      text = GreetingCatalog::SYSTEM_PHRASES.dig(phrase, lang) ||
             GreetingCatalog::SYSTEM_PHRASES.dig(phrase, "it") ||
             "Arrivederci."
      cc_client.speak(call.call_control_id,
        payload: text,
        voice: "alice",
        language: language_locale(lang))
    end
  end

  def play_greeting(call)
    tenant = call.tenant
    lang = caller_language(call)
    audio  = greeting_audio_url_for(tenant, slug: tenant.greeting_variant, language: lang)

    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: GreetingCatalog.text_for(tenant.greeting_variant, language: lang) ||
                 tenant.greeting_text ||
                 Setting.get("greeting_text"),
        voice: "alice",
        language: language_locale(lang))
    end
  end

  # Language to use for greeting + Whisper. Either auto-detected from the
  # caller's E.164 prefix (Italian if +39, English otherwise) or pinned to
  # the tenant's configured greeting_language when auto-detect is off.
  def caller_language(call)
    tenant = call.tenant
    if tenant.auto_detect_language
      GreetingCatalog.language_for_number(call.from_number)
    else
      tenant.greeting_language.to_s.start_with?("it") ? "it" : "en"
    end
  end

  # Map two-letter language code to full Telnyx-accepted locale.
  def language_locale(lang)
    lang.to_s == "it" ? "it-IT" : "en-US"
  end

  def start_voicemail(call)
    # Used by the legacy whitelisted-voicemail path (no screening).
    tenant = call.tenant
    lang = caller_language(call)
    audio = greeting_audio_url_for(tenant, slug: "voicemail_prompt", language: lang)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      text = GreetingCatalog::SYSTEM_PHRASES.dig("voicemail_prompt", lang) ||
             GreetingCatalog::SYSTEM_PHRASES.dig("voicemail_prompt", "it")
      cc_client.speak(call.call_control_id,
        payload: text,
        voice: "alice", language: language_locale(lang))
    end
    cc_client.record_start(call.call_control_id,
      max_length: tenant.max_recording_seconds || 120,
      play_beep: true)
    call.update!(flow_state: "recording", status: :recording)
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

  def forward_or_record(call, tenant)
    target = tenant.forward_back_number.presence || ENV["FORWARD_NUMBER"]
    if target.present?
      call.update!(flow_state: "transfer_dialing")
      cc_client.transfer(call.call_control_id, to: target, timeout_secs: 15)
    else
      start_voicemail(call)
    end
  end

  # Picks the pre-rendered audio URL for a greeting/system phrase.
  # Resolution priority:
  #
  #   1. Voice ROTATION (when enabled): cycle through the tenant's list
  #      of voice ids (which may include _t<id> for the cloned voice).
  #      One pick per call — atomic counter on Tenant.
  #   2. CLONED voice (when voice_clone_active + rendered).
  #   3. Default Kokoro voice in the caller's language (auto-swapped via
  #      GreetingCatalog::VOICE_LANGUAGE_PAIRS).
  #
  # Returns nil if no rendered file exists at any tier → caller falls
  # back to Telnyx <speak> in the parent helper.
  def greeting_audio_url_for(tenant, slug:, language: nil)
    return nil unless slug
    return nil unless GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
    tone = tenant.greeting_tone
    return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)

    # 1. Rotation (when enabled). The rotation list can mix Kokoro voice
    # ids and the cloned-voice _t<id>; both are handled by audio_url_for_voice.
    if tenant.voice_rotation_ready?
      rotated = tenant.next_rotated_voice!
      url = audio_url_for_voice(slug: slug, voice: rotated, tone: tone, language: language)
      return url if url
      # Fall through if the rotated voice has no file rendered yet.
    end

    # 2. Cloned-voice path
    if tenant.voice_clone_ready?
      url = audio_url_for_voice(slug: slug, voice: tenant.cloned_voice_dir, tone: tone, language: language)
      return url if url
    end

    # 3. Default Kokoro voice (gender-matched to language)
    audio_url_for_voice(slug: slug, voice: tenant.greeting_voice, tone: tone, language: language)
  end

  # Returns a public URL for one specific (slug, voice, tone) combo if
  # the rendered file exists. Handles both Kokoro voices (where the
  # voice id encodes language) and cloned voices (where language is
  # encoded in the tone filename suffix).
  def audio_url_for_voice(slug:, voice:, tone:, language: nil)
    return nil if voice.blank?
    voice_str = voice.to_s

    if voice_str.start_with?("_t")
      # Cloned voice — language is encoded in the filename suffix.
      effective_voice = voice_str
      effective_tone  = (language && language != "it") ? "#{tone}_en" : tone
    else
      # Kokoro voice — auto-swap to language equivalent.
      effective_voice = language ? GreetingCatalog.voice_for_language(voice_str, language) : voice_str
      effective_tone  = tone
      return nil unless Setting::ALLOWED_VOICES.include?(effective_voice)
    end

    return nil unless GreetingsStorage.path_for(slug, effective_voice, effective_tone).exist?
    "#{ENV.fetch('APP_DOMAIN', 'https://phone.example.com')}/greetings/#{slug}/#{effective_voice}/#{effective_tone}.wav"
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
