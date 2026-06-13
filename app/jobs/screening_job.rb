# Runs after the screening recording is saved by Telnyx. Downloads the
# audio, transcribes with Whisper, classifies the transcript, and decides
# the call's final disposition. The recording IS the voicemail — there's
# no separate voicemail prompt after screening.
class ScreeningJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Transport failures (recording download / Whisper) are transient: retry
  # with backoff rather than committing a wrong disposition. WhisperClient now
  # raises TransportError on a sidecar outage instead of returning nil, so an
  # outage no longer masquerades as "the caller said nothing" (status:
  # :unknown). RecordingDownloader raises TransientError on 5xx/429/timeouts
  # so a transient download blip no longer dead-letters.
  RETRYABLE = [
    Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error,
    WhisperClient::TransportError, RecordingDownloader::TransientError
  ].freeze

  # When retries are exhausted, surface the failure to the operator (Sentry +
  # an ntfy alert) and mark the call :failed — otherwise a real caller's
  # screening could fail silently with no signal.
  retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 4) do |job, error|
    report_terminal_failure(job.arguments.first, error)
  end

  def self.report_terminal_failure(call_id, error)
    Rails.logger.error("ScreeningJob giving up on call #{call_id}: #{error.class}: #{error.message}")
    Sentry.capture_exception(error) if defined?(Sentry)
    call = Call.find_by(id: call_id)
    return unless call

    if call.recording_url.present?
      # We have the voicemail audio — only transcription/classification failed
      # (e.g. a sustained Whisper outage). Degrade gracefully to a voicemail the
      # operator can still act on, rather than a dead :failed with no recourse
      # (P2-5). The operator listens via the authenticated recording playback.
      call.update!(status: :voicemail) unless call.status == "voicemail"
      return if call.notified_at?
      NtfyNotifier.notify(
        title: "📨 Messaggio vocale da #{call.contact_name}",
        message: "Da: #{call.from_number}\nTrascrizione non disponibile — ascolta la registrazione nell'app.",
        priority: "high",
        tags: [ "envelope_with_arrow" ],
        url: call.tenant&.ntfy_url,
        default_priority: call.tenant&.ntfy_priority,
        call: call
      )
      call.update!(notified_at: Time.current)
    else
      call.update!(status: :failed)
      return if call.notified_at?
      NtfyNotifier.notify(
        title: "⚠️ Screening non riuscito",
        message: "Impossibile classificare la chiamata da #{call.from_number} (#{error.class}).",
        priority: "high",
        tags: [ "warning" ],
        url: call.tenant&.ntfy_url,
        default_priority: call.tenant&.ntfy_priority
      )
      call.update!(notified_at: Time.current)
    end
  end

  def perform(call_id)
    call = Call.find(call_id)
    tenant = call.tenant

    local_path = RecordingDownloader.fetch(call)
    # Pass the same language the screener used to greet the caller so
    # Whisper hints work right (Italian-vs-English).
    lang = caller_language(call)
    transcript = WhisperClient.new(local_path, language: lang).transcribe.to_s.strip

    call.update!(
      recording_local_path: local_path,
      screening_transcript: transcript,
      voicemail_transcript: transcript
    )

    if transcript.blank?
      finalize(call, status: :unknown)
      return
    end

    # Keyword-block rules short-circuit the LLM.
    keyword_rule = tenant.rules.active.keyword.find { |r| r.matches_transcript?(transcript) }
    if keyword_rule&.action_block?
      keyword_rule.increment!(:hit_count)
      classification = {
        "classification" => "spam",
        "confidence" => 1.0,
        "reason" => "Keyword rule: #{keyword_rule.value}"
      }
      finalize(call, status: :spam, ai_classification: classification, source: "keyword")
      auto_blacklist_if_pattern_match(call)
      return
    end

    sensitivity = tenant.spam_sensitivity || Setting.get("spam_sensitivity").to_f
    # Feed the classifier this tenant's operator corrections (few-shot) + a
    # per-caller history hint, so manual feedback compounds (P2-2).
    feedback = ClassifierFeedback.for(tenant: tenant, contact: call.contact)
    hints = [ feedback.contact_hint, attestation_hint(call) ].compact.join(" ")
    result = SpamClassifier.new(transcript, from_number: call.from_number,
                                sensitivity: sensitivity,
                                examples: feedback.examples,
                                contact_hint: hints.presence).classify

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        finalize(call, status: :spam, ai_classification: result, source: "llm")
        auto_blacklist_if_pattern_match(call)
      else
        finalize(call, status: :uncertain, ai_classification: result, source: "llm")
      end
    when "legit"
      finalize(call, status: :legit, ai_classification: result, source: "llm")
    else
      finalize(call, status: :uncertain, ai_classification: result, source: "llm")
    end
  rescue *RETRYABLE
    # Defer to retry_on: re-raise so the backoff/exhaustion handler runs.
    # Do NOT mark :failed per-attempt (a later attempt may succeed).
    raise
  rescue => e
    # Non-retryable / unexpected error → terminal now. Surface it.
    self.class.report_terminal_failure(call_id, e)
    raise
  end

  private

  # Update only the classification fields. The controller owns flow_state
  # and the leg lifecycle (it sends the goodbye + hangup the moment the
  # recording arrives, so by the time this job finishes the leg is
  # usually already closed). Touching flow_state here would race with
  # handle_playback_or_speak_ended.
  def finalize(call, status:, ai_classification: nil, source: nil)
    attrs = { status: status }
    if ai_classification
      tokens_in  = ai_classification["tokens_in"]
      tokens_out = ai_classification["tokens_out"]
      attrs[:ai_classification] = ai_classification.except("tokens_in", "tokens_out")
      attrs[:ai_classification_source] = source if source
      if source == "llm"
        attrs[:moonshot_tokens_in]  = tokens_in
        attrs[:moonshot_tokens_out] = tokens_out
        attrs[:moonshot_cost_usd]   = Pricing.moonshot_usd(tokens_in, tokens_out)
      elsif source.present?
        attrs[:moonshot_cost_usd] = 0.0
      end
    end
    call.update!(attrs)
    NotifyJob.perform_later(call.id)
  end

  def caller_language(call)
    LanguageResolver.for(call)
  end

  # Soft anti-spoofing hint from STIR/SHAKEN attestation (P2-5). Never a hard
  # block — carrier-forwarded calls (the common path here) strip attestation.
  def attestation_hint(call)
    att = call.attestation.to_s.strip
    return nil if att.blank?
    if att.casecmp("A").zero? || att.downcase.include?("passed")
      "Caller ID attestation: #{att} (carrier-verified — spoofing unlikely)."
    else
      "Caller ID attestation: #{att} (NOT fully verified — the number may be spoofed)."
    end
  end

  def auto_blacklist_if_pattern_match(call)
    tenant = call.tenant
    contact = call.contact
    return unless contact
    return if contact.blacklisted? || contact.whitelisted?

    threshold = tenant.auto_blacklist_threshold
    window    = tenant.auto_blacklist_window_days
    # A nil threshold DISABLES auto-blacklist — that's the documented off switch
    # (the validator forbids 0, so nil is the only way to turn it off). The
    # previous `|| 3` silently re-enabled it at the default, so an operator who
    # cleared the field still got blacklisting. A set value is >= 1 per the
    # validator.
    return if threshold.nil? || threshold.to_i <= 0
    window = window.nil? ? 7 : window.to_i
    return if window <= 0

    count = contact.recent_spam_count(within: window.days)
    return if count < threshold.to_i

    contact.update!(blacklisted: true)
    AuditLog.record(
      action: "auto_blacklist", subject: contact, tenant: tenant,
      from: call.from_number, spam_count: count,
      window_days: window, threshold: threshold.to_i
    )
  end
end
