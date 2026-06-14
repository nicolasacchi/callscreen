class NotifyJob < ApplicationJob
  queue_as :default
  # Absorbs the race where a Call is destroyed (e.g. by e2e teardown,
  # or operator manual delete) between ScreeningJob's enqueue and our
  # perform. Without this the job retries until the dead set, polluting
  # SolidQueue with no value.
  discard_on ActiveRecord::RecordNotFound

  # A push that the ntfy server rejected (or a transport error) is released and
  # retried with backoff rather than lost forever — a misconfigured topic or a
  # transient 5xx then self-heals instead of silently dropping every call.
  retry_on NtfyNotifier::DeliveryError, wait: :polynomially_longer, attempts: 5 do |job, error|
    Rails.logger.error("NotifyJob gave up after retries: #{error.message}")
    Sentry.capture_exception(error) if defined?(Sentry)
  end

  def perform(call_id)
    call = Call.find(call_id)
    # Atomic claim: exactly one concurrent NotifyJob for this call wins, so a
    # call can't be pushed twice (e.g. apply_spam_response enqueues one and a
    # later ScreeningJob#finalize enqueues another, racing across the 3
    # :default threads). notified_at is the claim token.
    return if Call.where(id: call.id, notified_at: nil).update_all(notified_at: Time.current).zero?

    # NtfyNotifier returns false only on a real send failure (non-2xx / raised
    # transport error); a suppressed "disabled" tenant returns true. On failure,
    # release the claim and raise so retry_on re-attempts — a rare double-send is
    # far better than a permanently lost notification.
    unless send_notification(call)
      Call.where(id: call.id).update_all(notified_at: nil)
      raise NtfyNotifier::DeliveryError, "ntfy push failed for call #{call.id}"
    end
  end

  private

  def send_notification(call)
    tenant        = call.tenant
    ntfy_url      = tenant&.ntfy_url
    ntfy_priority = tenant&.ntfy_priority
    # Use contact_name in the title — falls back to the raw number when the
    # contact has no name (or no matching contact). Body always includes the raw
    # number so the operator sees both.
    caller = call.contact_name

    if call.spam?
      NtfyNotifier.notify(
        title: "📵 Spam: #{caller}", message: spam_message(call),
        priority: "low", tags: [ "no_entry", "spam" ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    elsif call.status == "uncertain"
      # Low-confidence spam: must NOT be presented as a clean high-priority legit
      # call. Distinct title + default priority so the operator triages it.
      NtfyNotifier.notify(
        title: "⚠️ Incerto: #{caller}", message: uncertain_message(call),
        priority: "default", tags: [ "phone", "question" ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    elsif call.status == "unknown" && call.recording_url.blank?
      # Abandoned during screening: caller hung up before/while the screening
      # prompt played, so no recording was ever captured. A low-priority
      # missed-call alert (the operator still sees the inbound attempt).
      NtfyNotifier.notify(
        title: "📞 Chiamata persa: #{caller}", message: abandoned_message(call),
        priority: "low", tags: [ "phone" ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    elsif call.status == "unknown"
      # Recorded but silent: caller stayed on the line but said nothing
      # classifiable (blank transcript). Worth a normal-priority heads-up.
      NtfyNotifier.notify(
        title: "❓ Sconosciuto: #{caller}", message: unknown_message(call),
        priority: "default", tags: [ "phone", "question" ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    elsif %w[legit completed voicemail].include?(call.status)
      NtfyNotifier.notify(
        title: "📞 Da #{caller}", message: legit_message(call),
        priority: "high", tags: [ "phone", call.status ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    else
      # Defensive: an unexpected terminal status (e.g. initiated/screening
      # reaching here via a bug) shouldn't be silently shown as a clean call.
      Rails.logger.warn("NotifyJob: unexpected status #{call.status.inspect} for call #{call.id}")
      Sentry.capture_message("NotifyJob unexpected status #{call.status}") if defined?(Sentry)
      NtfyNotifier.notify(
        title: "📞 Chiamata da #{caller}", message: legit_message(call),
        priority: "high", tags: [ "phone" ],
        url: ntfy_url, tenant_priority: ntfy_priority, call: call
      )
    end
  end

  def spam_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << call.ai_summary if call.ai_summary           # one-line TL;DR (P2-3)
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    tail = []
    tail << "Motivo: #{call.ai_reason}" if call.ai_reason
    tail << "Confidenza: #{call.confidence_pct}%" if call.confidence_pct
    parts << "" if tail.any?
    parts.concat(tail)
    parts.join("\n").strip
  end

  def uncertain_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << call.ai_summary if call.ai_summary
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "L'AI non è sicura della classificazione (possibile spam)."
    parts << "Motivo: #{call.ai_reason}" if call.ai_reason
    parts << "Confidenza: #{call.confidence_pct}%" if call.confidence_pct
    parts << global_spam_line(call) if global_spam_line(call)
    parts.join("\n").strip
  end

  def legit_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << call.ai_summary if call.ai_summary           # one-line TL;DR (P2-3)
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Classificazione: #{call.status}#{ai_confidence_suffix(call)}"
    # A call the AI cleared but railsdav's cross-tenant DB flags is exactly the
    # case the single-call classifier can't see — surface it loudly.
    parts << global_spam_line(call) if global_spam_line(call)
    parts.join("\n").strip
  end

  def unknown_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << "Il chiamante non ha detto nulla."
    parts.join("\n").strip
  end

  def abandoned_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << "Ha riagganciato durante lo screening (nessun messaggio)."
    parts.join("\n").strip
  end

  def ai_confidence_suffix(call)
    return "" unless call.confidence_pct
    " (#{call.confidence_pct}%)"
  end

  # Cross-tenant corroboration from railsdav's global spam DB (persisted on the
  # Call at call.initiated). nil unless this number is globally reported.
  def global_spam_line(call)
    return nil unless call.spam_global?
    meta  = call.spam_global_meta
    count = meta["report_count"].to_i
    src   = meta["source"].to_s.presence
    parts = [ "⚠️ Nel DB spam globale" ]
    parts << "#{count} segnalazioni" if count.positive?
    parts << "fonte: #{src}" if src
    parts.join(" — ")
  end
end
