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
  #   call.recording.saved → goodbye + ScreeningJob    state=hanging_up_after_speak
  #   ScreeningJob → Whisper → SpamClassifier → finalize
  #   call.hangup → mark done

  CALL_CONTROL_ID_FORMAT = /\A[A-Za-z0-9_:=\-]{1,256}\z/
  SCREENING_RECORDING_MAX_SECS = 30
  # Stop recording after this many seconds of silence. Lets a caller who
  # said "Sono Mario, chiamo per la cena" finish + pause + get hung up
  # in ~8s instead of waiting the full max_length=30s timeout. Default when
  # the tenant's screening_speech_timeout is "auto"/blank.
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
    when "call.bridged"            then handle_bridged(payload)
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
    # railsdav's cached_display_name is the canonical book entry (recomputed from
    # the vCard on every CardDAV sync). Re-sync it even over a stale local name so
    # an address-book rename propagates to the screener; a manual callscreen
    # rename is intentionally re-synced. Diff-guarded to avoid no-op writes.
    if external.matched? && external.name.present? && external.name != contact.name
      contact.name = external.name
    end
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
      attestation: extract_attestation(p),
      spam_global: external.spam_global?,
      external_lookup_meta: external_lookup_snapshot(external),
      unattributed: tenant_unattributed?(tenant, to: to, sip_headers: sip_headers)
    }

    # Idempotent: if Telnyx retries call.initiated we should not duplicate.
    call = Call.find_or_initialize_by(call_control_id: ccid)
    call.assign_attributes(call_attrs) if call.new_record?
    call.save!

    # Decide accept/block via the CallPolicy ladder, then apply it. Keeping the
    # decision pure (no side effects) makes the "who gets through" rules
    # independently testable; the controller owns the side effects below.
    decision = CallPolicy.decide(contact: contact, tenant: tenant, external: external, from: from)
    decision.rule&.increment!(:hit_count)
    apply_decision(call, tenant, decision, ccid: ccid)
  end

  # Applies a CallPolicy::Decision: issue the configured spam response, forward
  # an allowed caller, or answer-and-screen by default.
  def apply_decision(call, tenant, decision, ccid:)
    case decision.disposition
    when :spam
      apply_spam_response(call, tenant, ccid: ccid,
                          reason: decision.reason, source: decision.source,
                          force_silent: decision.force_silent, notify: decision.notify)
    when :allow
      call.update!(status: :legit, flow_state: "transfer_dialing")
      forward_or_record(call, tenant)
    when :answer
      call.update!(status: :screening, flow_state: "answered")
      cc_client.answer(ccid)
    end
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

    # Telnyx reports playback/speak failure as this same event with a non-
    # "completed" status (there is no separate failure event). Surface it for
    # observability; the FSM transitions below are safe either way (a failed
    # greeting still proceeds to record; a failed goodbye still hangs up).
    status = p["status"].to_s
    if status.present? && status != "completed"
      Rails.logger.warn("playback/speak ended status=#{status.inspect} call=#{call.id} flow_state=#{call.flow_state}")
    end

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
        timeout_secs: screening_silence_timeout(call.tenant),
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
    # A delivery with no URL carries nothing to process; ignore it so a later
    # delivery that DOES carry the URL still wins the flow_state claim below
    # (rather than a nil-URL delivery winning and stranding ScreeningJob with
    # no recording to fetch).
    return if url.blank?

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
      # Enqueue classification FIRST — it is the load-bearing work. The goodbye
      # is cosmetic, but it can raise (e.g. a SQLite busy error in
      # VoiceSelector's update_columns under contention). If it raised
      # before the enqueue, a real caller would be screened, hung up on, and
      # NEVER classified or notified — the worst silent failure in the product.
      # So enqueue, then play the goodbye inside a guard that can't block it.
      ScreeningJob.perform_later(call.id)
      begin
        play_goodbye(call, phrase: "goodbye_spam")
      rescue StandardError => e
        Rails.logger.error("play_goodbye failed for call #{call.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end
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

  # A transfer connected. Move out of the transient transfer_dialing state into
  # "bridged" so the live operator conversation is never touched by the
  # stuck-call sweep — and, conversely, so a transfer that NEVER bridges (stays
  # transfer_dialing past the sweep cutoff) becomes sweepable instead of
  # stranding the caller in dead air.
  def handle_bridged(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call
    call.update!(flow_state: "bridged") if call.flow_state == "transfer_dialing"
  end

  def handle_hangup(payload)
    p    = payload.dig("data", "payload") || {}
    ccid = p["call_control_id"]
    call = Call.find_by(call_control_id: ccid)
    return unless call

    finalize_billing(call)
    finalize_abandoned_screening(call)

    call.update!(flow_state: "done") unless call.flow_state == "done"
    if call.contact.present?
      call.contact.update!(last_called_at: Time.current)
    end
  end

  # Flow states reached in screening BEFORE record_start fires. A hangup here
  # means the caller dropped during/before the screening prompt, so no recording
  # will ever arrive (vs "screening_recording", where a recording.saved may still
  # be in flight — those are left to ReconcileStuckScreeningsJob after a grace
  # period so a real recording wins the race).
  ABANDONED_BEFORE_RECORDING = %w[answered screening_prompt_playing].freeze

  # Caller hung up during screening without leaving a recording — finalize to
  # :unknown and notify so the operator still sees the missed inbound call,
  # instead of stranding it at status :screening forever with no push.
  def finalize_abandoned_screening(call)
    return unless call.status == "screening"
    return unless call.notified_at.nil?
    return if call.recording_url.present?
    return unless ABANDONED_BEFORE_RECORDING.include?(call.flow_state)

    call.update!(status: :unknown)
    NotifyJob.perform_later(call.id)
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

  # Best-effort STIR/SHAKEN attestation capture from the call.initiated payload.
  # Telnyx's exact field placement varies by configuration, so probe the likely
  # locations defensively; absent → nil (the common carrier-forwarded case).
  # Used only as a soft classifier hint, never a hard block.
  def extract_attestation(payload)
    ss = payload["stir_shaken"]
    if ss.is_a?(Hash)
      return (ss["attestation_level"] || ss["attestation"] || ss["verstat"]).to_s.presence
    end
    return ss.to_s.presence if ss.is_a?(String)
    payload["verstat"].to_s.presence
  end

  def tenant_unattributed?(tenant, to:, sip_headers:)
    # If we matched by dedicated_number or by History-Info that's an
    # attributed call. Only the fallback to default counts as unattributed.
    !(tenant.dedicated_number.present? && tenant.dedicated_number == to.to_s) &&
      SipHeadersParser.original_called_number(sip_headers) != tenant.mobile_number
  end

  # === Outbound command shortcuts ===

  # Play a pre-rendered WAV if we have one, else fall back to Telnyx TTS
  # (alice) with the given text. Single home for the four play_* helpers'
  # identical playback-or-speak tail (CQ-8).
  def play_audio_or_speak(call, audio_url:, fallback_text:, lang:)
    if audio_url
      cc_client.playback_start(call.call_control_id, audio_url: audio_url)
    else
      cc_client.speak(call.call_control_id,
        payload: fallback_text,
        voice: "alice",
        language: language_locale(lang))
    end
  end

  # Short "thanks, goodbye" before hangup. Pre-rendered audio if available;
  # falls back to TTS via speak. The follow-up call.speak.ended OR
  # call.playback.ended (state=hanging_up_after_speak) issues the hangup.
  def play_goodbye(call, phrase:)
    lang  = caller_language(call)
    voice = VoiceSelector.for_call!(call)
    audio = GreetingAudioResolver.url(tenant: call.tenant, slug: phrase, voice: voice, language: lang)
    play_audio_or_speak(call, audio_url: audio,
                        fallback_text: phrase_text(phrase, lang) || "Arrivederci.", lang: lang)
  end

  def play_greeting(call)
    tenant = call.tenant
    lang   = caller_language(call)
    now    = e2e_injected_time || Time.current
    phrase = PhrasePoolResolver.new(call: call, now: now).resolve!
    voice  = VoiceSelector.for_call!(call)
    if phrase
      call.update_columns(selected_phrase_slug: phrase.slug)
      Rails.logger.info("phrase_resolver: call_control_id=#{call.call_control_id} slug=#{phrase.slug} voice=#{voice}")
    end
    slug  = phrase&.slug || tenant.greeting_variant
    audio = GreetingAudioResolver.url(tenant: tenant, slug: slug, voice: voice, language: lang)
    play_audio_or_speak(call, audio_url: audio,
                        fallback_text: phrase_text(slug, lang) || tenant.greeting_text || Setting.get("greeting_text"),
                        lang: lang)
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
    voice  = tenant.greeting_voice  # forced Kokoro, bypasses VoiceSelector
    audio  = GreetingAudioResolver.url_for_voice(slug: slug, voice: voice,
                                                 tone: tenant.greeting_tone, language: lang)
    play_audio_or_speak(call, audio_url: audio, fallback_text: phrase_text(slug, lang) || "", lang: lang)
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
    # report_count now lives in the persisted railsdav snapshot (it was never
    # written to ai_classification, so this previously always scored the 0.5
    # floor). external_lookup_meta is set in handle_initiated before this runs.
    count = call.external_lookup_meta&.dig("spam_metadata", "report_count").to_i
    count = 1 if count <= 0
    (count.to_f / 5).clamp(0.5, 1.0)
  end

  # Snapshot the railsdav lookup for persistence on the Call — the admin view,
  # the ntfy global-spam line, and spam_confidence_for read it later, but the
  # live Result is otherwise discarded after CallPolicy. nil when there's
  # nothing worth storing (unknown caller, no global-spam hit).
  def external_lookup_snapshot(external)
    return nil unless external.matched? || external.spam_global?
    {
      "policy" => external.policy,
      "addressbook" => external.addressbook,
      "contact_id" => external.contact_id,
      "kind" => external.kind,
      "groups" => external.groups.presence,
      "spam_metadata" => external.spam_metadata.presence
    }.compact
  end

  # Returns the text for a phrase by slug, preferring the system row
  # (`tenant_id IS NULL`) over any tenant-authored row that happens to
  # share the slug. Reserved-slug validation prevents new collisions on
  # creation, but pre-existing tenant rows could otherwise win the
  # lookup and bypass the seeded system text.
  # Phrase text comes from the DB exclusively (ARCH-4): db:seed re-creates every
  # system Phrase row idempotently on each boot, so a miss here is a seed/render
  # bug worth surfacing — not a normal case to silently paper over with the
  # GreetingCatalog constant (which is now seed-data + structural metadata only).
  # Returning nil is safe: callers fall back to tenant.greeting_text / TTS.
  def phrase_text(slug, lang)
    return nil if slug.blank?
    p = Phrase.where(slug: slug.to_s).order(Arel.sql("tenant_id IS NULL DESC")).first
    return p.text(lang) if p && p.text(lang).present?
    Rails.logger.warn("phrase_text: no Phrase row for slug=#{slug.inspect} lang=#{lang.inspect} — check db:seed")
    nil
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

  # Per-tenant silence cutoff for the screening recording. The tenant's
  # screening_speech_timeout column was previously inert (the call flow
  # hardcoded the constant); now it's honoured. Value is "auto"/blank (→
  # default) or an integer 1..60 (validated on the Tenant model).
  def screening_silence_timeout(tenant)
    raw = tenant.screening_speech_timeout.to_s.strip
    return SCREENING_SILENCE_TIMEOUT_SECS if raw.blank? || raw == "auto"
    (Integer(raw, exception: false) || SCREENING_SILENCE_TIMEOUT_SECS).clamp(1, 60)
  end

  def start_voicemail(call)
    # Used by the legacy whitelisted-voicemail path (no screening).
    tenant = call.tenant
    lang  = caller_language(call)
    voice = VoiceSelector.for_call!(call)
    audio = GreetingAudioResolver.url(tenant: tenant, slug: "voicemail_prompt", voice: voice, language: lang)
    play_audio_or_speak(call, audio_url: audio, fallback_text: phrase_text("voicemail_prompt", lang), lang: lang)
    cc_client.record_start(call.call_control_id,
      max_length: tenant.max_recording_seconds || 120,
      play_beep: true)
    call.update!(flow_state: "recording", status: :recording)
  end

  def forward_or_record(call, tenant)
    target = tenant.forward_back_number.presence || ENV["FORWARD_NUMBER"]
    return start_voicemail(call) if target.blank?

    # Only commit to transfer_dialing once Telnyx accepts the transfer. The
    # stuck-call sweep deliberately skips transfer_dialing (a bridged leg fires
    # no events), so a silently-failed transfer left in that state would strand
    # the caller in indefinite dead air. On failure, fall back to voicemail so
    # they can still leave a message.
    if cc_client.transfer(call.call_control_id, to: target, timeout_secs: 15)[:ok]
      call.update!(flow_state: "transfer_dialing")
    else
      Rails.logger.warn("transfer to #{target} failed for call #{call.id}; falling back to voicemail")
      Sentry.capture_message("Call transfer command failed; fell back to voicemail (call #{call.id})") if defined?(Sentry)
      start_voicemail(call)
    end
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
