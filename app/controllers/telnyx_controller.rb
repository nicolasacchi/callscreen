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

    # 0. Per-caller rate limit (within 15min). Whitelisted callers and
    # railsdav-allowed callers are exempt from this gate so a known good
    # caller never gets blocked by a high call volume.
    # Always silent regardless of tenant.spam_response_mode — the same
    # caller hammering us in time-waster mode would self-DoS our Telnyx bill.
    if rate_limit_exceeded?(contact, tenant: tenant, external: external)
      limit = tenant.max_calls_per_caller_per_day || 10
      apply_spam_response(call, tenant, ccid: ccid,
                          reason: "Rate limited (more than #{limit} calls in 24h)",
                          source: "rate_limit",
                          force_silent: true)
      return
    end

    # 1. Railsdav (centralized contacts) policy
    if external.matched?
      case external.policy
      when "block"
        apply_spam_response(call, tenant, ccid: ccid,
                            reason: "Railsdav policy: block (#{external.addressbook})",
                            source: "railsdav")
        return
      when "allow"
        call.update!(status: :legit, flow_state: "transfer_dialing")
        forward_or_record(call, tenant)
        return
      end
    end

    # 2. Local blacklist (operator override).
    # Preserves historical silent-no-notify behavior: an operator who
    # blacklists a number doesn't want a push every time it dials in.
    if contact.blacklisted?
      apply_spam_response(call, tenant, ccid: ccid,
                          reason: "Contact blacklisted by operator",
                          source: "blacklist",
                          notify: false)
      return
    end

    # 3. Local whitelist (operator override)
    if contact.whitelisted?
      call.update!(status: :legit, flow_state: "transfer_dialing")
      forward_or_record(call, tenant)
      return
    end

    # 3.5. Cross-tenant global spam DB (railsdav-mastered).
    # Placed AFTER both railsdav `policy=allow` and local whitelist so
    # operator-curated allowlists override the global list — a friend
    # whose number was scraped into a community feed still gets through.
    if external.spam_global?
      apply_spam_response(call, tenant, ccid: ccid,
                          reason: spam_global_reason(external),
                          source: "spam_db_global")
      return
    end

    # 4. Per-tenant rules (prefix/regex).
    # action_block is always silent — operator-defined hard blocks
    # semantically mean "this should never reach me".
    rule_match = tenant.rules.active.find { |r| r.matches_number?(from) }
    if rule_match
      rule_match.increment!(:hit_count)
      if rule_match.action_block?
        apply_spam_response(call, tenant, ccid: ccid,
                            reason: "Tenant rule blocked",
                            source: "rule",
                            force_silent: true)
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

    call.update!(answered_at: Time.current) if call.answered_at.nil?

    case call.flow_state
    when "answered"
      # Play the greeting. Caller speech will be captured by the
      # follow-up record_start that fires on call.playback.ended.
      call.update!(flow_state: "screening_prompt_playing")
      play_greeting(call)
    when "transfer_dialing"
      # Allow path triggered transfer immediately on initiated; nothing to do.
    when "spam_disclose_playing"
      play_spam_response_audio(call, "spam_disclose")
    when "troll_playing"
      play_troll_segment(call)
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
    when "spam_disclose_playing"
      # Single-segment polite disclose finished → hangup.
      call.update!(flow_state: "done")
      cc_client.hangup(ccid)
    when "troll_playing"
      advance_troll_or_hangup(call)
    end
  end

  def handle_recording_saved(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    url  = p["recording_urls"]&.values&.first || p["recording_url"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    attrs = { recording_url: url, duration_seconds: p["duration_seconds"].to_i }

    # Idempotent + race-safe. Telnyx fires recording.saved twice (the action
    # callback and the recordingStatusCallback). We claim the work with an
    # atomic flow_state transition, so only the first delivery proceeds — even
    # if two arrive concurrently, or the first carries no recording_url.
    # (Keying the dedupe on flow_state instead of recording_url avoids the
    # double-goodbye / double-ScreeningJob a nil first URL previously risked.)
    if Call.where(id: call.id, flow_state: "screening_recording")
           .update_all(attrs.merge(flow_state: "hanging_up_after_speak")).positive?
      # Caller is still on the line — close their leg promptly so they don't
      # hear ~30 s of silence while Whisper + the LLM run. Play a short
      # goodbye and hang up on speak.ended (hanging_up_after_speak branch).
      # Classification continues async in ScreeningJob.
      call.reload
      play_goodbye(call, phrase: "goodbye_spam")
      ScreeningJob.perform_later(call.id)
    elsif Call.where(id: call.id, flow_state: "recording")
              .update_all(attrs.merge(status: Call.statuses[:completed], flow_state: "done")).positive?
      # Legacy whitelisted-voicemail path (greeting + record, no screening).
      TranscribeRecordingJob.perform_later(call.id)
      cc_client.hangup(ccid)
    else
      # Already advanced past the recording states — a duplicate or stale
      # delivery. Don't re-hang up; the original leg is already being handled.
      Rails.logger.info("recording.saved in non-recording flow_state=#{call.flow_state}; ignoring")
    end
  end

  def handle_hangup(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    finalize_billing(call)

    call.update!(flow_state: "done") unless call.flow_state == "done"
    if call.contact.present?
      call.contact.update!(last_called_at: Time.current)
    end
  end

  # Captures hung_up_at and derives billable_seconds + telnyx_cost_usd
  # from the answered_at..hung_up_at window. Calls rejected before answer
  # have answered_at = nil and are billed at $0 (already set on the
  # reject paths).
  def finalize_billing(call)
    return if call.hung_up_at.present?  # idempotent; Telnyx may retry

    now = Time.current
    attrs = { hung_up_at: now }
    if call.answered_at.present?
      seconds = (now - call.answered_at).to_i.clamp(0, 7200)
      attrs[:billable_seconds] = seconds
      attrs[:telnyx_cost_usd]  = Pricing.telnyx_voice_usd(seconds)
    elsif call.telnyx_cost_usd.nil?
      attrs[:telnyx_cost_usd] = 0.0
    end
    call.update!(attrs)
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
    lang  = caller_language(call)
    voice = pick_voice_for_call!(call)
    audio = greeting_audio_url_for(tenant, slug: phrase, language: lang, voice: voice)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: phrase_text(phrase, lang) || "Arrivederci.",
        voice: "alice",
        language: language_locale(lang))
    end
  end

  def play_greeting(call)
    tenant = call.tenant
    lang   = caller_language(call)
    now    = e2e_injected_time || Time.current
    phrase = PhrasePoolResolver.new(call: call, now: now).resolve!
    voice  = pick_voice_for_call!(call)
    if phrase
      call.update_columns(selected_phrase_slug: phrase.slug)
      Rails.logger.info("phrase_resolver: call_control_id=#{call.call_control_id} slug=#{phrase.slug} voice=#{voice}")
    end
    slug   = phrase&.slug || tenant.greeting_variant
    audio  = greeting_audio_url_for(tenant, slug: slug, language: lang, voice: voice)

    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: phrase_text(slug, lang) || tenant.greeting_text || Setting.get("greeting_text"),
        voice: "alice",
        language: language_locale(lang))
    end
  end

  # === Spam-response audio ===

  # Sequence of phrase slugs played in time-waster mode. The cap on
  # tenant.spam_troll_max_seconds covers the "what if a caller stays for
  # 4 minutes" worst case; sequence length covers the normal happy path.
  TROLL_SEGMENTS = %w[troll_intro troll_hold_loop troll_voice_menu troll_apology troll_disclose].freeze

  # Plays a system phrase via Kokoro voice ONLY — never the rotation list
  # nor the cloned voice. A known-bad caller hearing the operator's
  # cloned voice for 90s is a clean voice-sample handoff for fraud /
  # impersonation. Falls back to Telnyx alice if no rendered WAV exists
  # (typically for the first call after a new tenant deploys before
  # PhraseRenderJob completes).
  def play_spam_response_audio(call, slug)
    tenant = call.tenant
    lang   = caller_language(call)
    voice  = tenant.greeting_voice  # forced Kokoro, bypasses pick_voice_for_call!
    audio  = audio_url_for_voice(slug: slug, voice: voice,
                                 tone: tenant.greeting_tone, language: lang)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: phrase_text(slug, lang) || "",
        voice: "alice",
        language: language_locale(lang))
    end
  end

  def play_troll_segment(call)
    idx  = call.troll_segment_index || 0
    slug = TROLL_SEGMENTS[idx]
    if slug.nil?
      cc_client.hangup(call.call_control_id)
      call.update!(flow_state: "done")
      return
    end
    play_spam_response_audio(call, slug)
  end

  # Advances troll_segment_index and either plays the next segment or
  # hangs up — when the sequence is exhausted OR when we've spent more
  # than tenant.spam_troll_max_seconds on the answered leg.
  def advance_troll_or_hangup(call)
    tenant = call.tenant
    elapsed = call.answered_at ? (Time.current - call.answered_at) : 0.0
    cap = (tenant.spam_troll_max_seconds || 90).to_i
    next_idx = (call.troll_segment_index || 0) + 1

    if next_idx >= TROLL_SEGMENTS.size || elapsed >= cap
      call.update!(flow_state: "done")
      cc_client.hangup(call.call_control_id)
      return
    end

    call.update!(troll_segment_index: next_idx)
    play_troll_segment(call)
  end

  # === Spam policy helpers ===

  # Single entrypoint for "this caller is spam — apply the configured
  # response." Replaces four scattered `cc_client.reject` blocks. Modes:
  #
  #   silent          → reject (no audio, $0)
  #   polite_disclose → answer + play `spam_disclose` + hangup
  #   time_waster     → answer + chain TROLL_SEGMENTS up to spam_troll_max_seconds
  #
  # `force_silent: true` overrides the tenant mode for hard-block sources
  # (rate-limit, rule action_block) where engagement is a self-DoS risk.
  # `notify: false` preserves the historic silent-no-push behavior of
  # local blacklist hits.
  def apply_spam_response(call, tenant, ccid:, reason:, source:,
                          force_silent: false, notify: true)
    mode = force_silent ? "silent" : tenant.spam_response_mode
    flow_state =
      case mode
      when "silent"          then "done"
      when "polite_disclose" then "spam_disclose_playing"
      when "time_waster"     then "troll_playing"
      else "done"
      end

    call.update!(
      status: :spam,
      flow_state: flow_state,
      ai_classification: {
        "classification" => "spam",
        "confidence" => spam_confidence_for(source, call),
        "reason" => reason
      },
      ai_classification_source: source,
      moonshot_cost_usd: 0.0,
      telnyx_cost_usd: (mode == "silent" ? 0.0 : nil)
    )
    NotifyJob.perform_later(call.id) if notify

    case mode
    when "silent"
      cc_client.reject(ccid)
    when "polite_disclose", "time_waster"
      cc_client.answer(ccid)
    else
      cc_client.reject(ccid)
    end
  end

  # Confidence derivation. LLM-classified spam stores a real value;
  # static-source rejects historically used 1.0. For spam_db_global,
  # scale from the railsdav report_count so feed-imported single-source
  # entries don't claim 100% confidence.
  def spam_confidence_for(source, call)
    return 1.0 unless source == "spam_db_global"
    meta  = call.ai_classification.is_a?(Hash) ? call.ai_classification : {}
    count = meta.dig("spam_metadata", "report_count").to_i
    count = 1 if count <= 0
    (count.to_f / 5).clamp(0.5, 1.0)
  end

  def spam_global_reason(external)
    meta   = external.spam_metadata || {}
    src    = meta["source"].to_s.presence
    count  = meta["report_count"].to_i
    parts  = [ "Global spam DB hit" ]
    parts << "source: #{src}" if src
    parts << "reports: #{count}" if count > 0
    parts.join(" — ")
  end

  # Picks the voice to use for every audio segment of this call's
  # lifetime (greeting + goodbye + voicemail prompt). Advances the
  # rotation cursor at most once per call by caching the picked voice
  # on `Call#selected_voice`. Subsequent invocations return the cached
  # value, so a single call never advances the cursor twice.
  def pick_voice_for_call!(call)
    return call.selected_voice if call.selected_voice.present?
    tenant = call.tenant
    voice =
      if tenant.voice_rotation_ready?
        tenant.next_rotated_voice!
      elsif tenant.voice_clone_ready?
        tenant.cloned_voice_dir
      else
        tenant.greeting_voice
      end
    call.update_columns(selected_voice: voice) if voice.present?
    voice
  end

  # Returns the text for a phrase by slug, preferring the system row
  # (`tenant_id IS NULL`) over any tenant-authored row that happens to
  # share the slug. Reserved-slug validation prevents new collisions on
  # creation, but pre-existing tenant rows could otherwise win the
  # lookup and bypass the seeded system text.
  def phrase_text(slug, lang)
    return nil if slug.blank?
    p = Phrase.where(slug: slug.to_s).order(Arel.sql("tenant_id IS NULL DESC")).first
    if p && p.text(lang).present?
      return p.text(lang)
    end
    GreetingCatalog.text_for(slug, language: lang) ||
      GreetingCatalog::SYSTEM_PHRASES.dig(slug.to_s, lang) ||
      GreetingCatalog::SYSTEM_PHRASES.dig(slug.to_s, "it")
  end

  # Language to use for greeting + Whisper. Delegates to LanguageResolver
  # which centralizes contact override + auto-detect + pinned-language
  # precedence. Kept here as a thin wrapper for backwards compat with
  # any in-flight callers within this controller.
  def caller_language(call)
    LanguageResolver.for(call)
  end

  # Map two-letter language code to full Telnyx-accepted locale.
  def language_locale(lang)
    lang.to_s == "it" ? "it-IT" : "en-US"
  end

  def start_voicemail(call)
    # Used by the legacy whitelisted-voicemail path (no screening).
    tenant = call.tenant
    lang  = caller_language(call)
    voice = pick_voice_for_call!(call)
    audio = greeting_audio_url_for(tenant, slug: "voicemail_prompt", language: lang, voice: voice)
    if audio
      cc_client.playback_start(call.call_control_id, audio_url: audio)
    else
      cc_client.speak(call.call_control_id,
        payload: phrase_text("voicemail_prompt", lang),
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
    contact.recent_calls_count(within: 15.minutes) > limit
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
  #
  # When `voice:` is given (the supported path post-2026-05-07), the
  # method skips rotation/clone selection entirely and just builds the
  # URL for the picked voice. The rotation cursor advance happens
  # exactly once per call in `pick_voice_for_call!`. Falls back to the
  # tenant's default greeting_voice if the file is missing for the
  # picked voice. The legacy code path (no `voice:`) is preserved as a
  # safety net for any caller that hasn't been migrated.
  def greeting_audio_url_for(tenant, slug:, language: nil, voice: nil)
    return nil unless slug
    # Slug must reference a known Phrase (DB-backed allowlist) — falls
    # back to GreetingCatalog::ALL_SLUGS for any in-flight references
    # the rewrite hasn't migrated yet.
    return nil unless Phrase.where(slug: slug.to_s).exists? ||
                      GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
    tone = tenant.greeting_tone
    return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)

    if voice.present?
      url = audio_url_for_voice(slug: slug, voice: voice, tone: tone, language: language)
      return url if url
      return audio_url_for_voice(slug: slug, voice: tenant.greeting_voice, tone: tone, language: language)
    end

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
    url = "#{ENV.fetch('APP_DOMAIN', 'https://phone.example.com')}/greetings/#{slug}/#{effective_voice}/#{effective_tone}.wav"
    # Cloned-voice greetings are served only with a valid signature so the
    # operator's voice WAVs aren't publicly harvestable (see GreetingSignature).
    if effective_voice.start_with?("_t")
      sig = GreetingSignature.encode(slug: slug, voice: effective_voice, tone: effective_tone)
      url = "#{url}?sig=#{CGI.escape(sig)}"
    end
    url
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
    return if synthetic_token_valid?
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

  # Separate auth path for `bin/synthetic_call`. Requires a distinct env
  # var (SYNTHETIC_WEBHOOK_TOKEN) which is unset by default, so this is
  # opt-in per-deployment and never accidentally exposes the live
  # webhook surface to anonymous requests. The synthetic script signs
  # its events with this token in the `?synthetic_token=…` param.
  def synthetic_token_valid?
    expected = ENV["SYNTHETIC_WEBHOOK_TOKEN"].to_s
    return false if expected.empty?
    ActiveSupport::SecurityUtils.secure_compare(params[:synthetic_token].to_s, expected)
  end

  # Optional time injection for e2e tests, gated on synthetic auth so
  # production Telnyx requests can never inject. Strict ISO8601 with
  # explicit timezone offset; on parse failure we log and fall back to
  # Time.current rather than silently masking the bug.
  def e2e_injected_time
    return nil unless synthetic_token_valid?
    raw = request.headers["X-E2E-Now"]
    return nil if raw.blank?
    Time.zone.iso8601(raw)
  rescue ArgumentError
    Rails.logger.warn("X-E2E-Now: parse failed for #{raw.inspect}; ignoring")
    nil
  end
end
