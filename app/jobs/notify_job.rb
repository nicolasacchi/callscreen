class NotifyJob < ApplicationJob
  queue_as :default
  # Absorbs the race where a Call is destroyed (e.g. by e2e teardown,
  # or operator manual delete) between ScreeningJob's enqueue and our
  # perform. Without this the job retries until the dead set, polluting
  # SolidQueue with no value.
  discard_on ActiveRecord::RecordNotFound

  def perform(call_id)
    call = Call.find(call_id)
    # Atomic claim: exactly one concurrent NotifyJob for this call wins, so a
    # call can't be pushed twice (e.g. apply_spam_response enqueues one and a
    # later ScreeningJob#finalize enqueues another, racing across the 3
    # :default threads). notified_at is the claim token. NtfyNotifier never
    # raises, so claiming before sending preserves the prior semantics.
    return if Call.where(id: call.id, notified_at: nil).update_all(notified_at: Time.current).zero?

    tenant = call.tenant
    ntfy_url      = tenant&.ntfy_url
    ntfy_priority = tenant&.ntfy_priority

    # Use contact_name in the title — falls back to the raw number when
    # the contact has no name (or no matching contact). Body always
    # includes the raw number so the operator sees both.
    caller = call.contact_name

    if call.spam?
      NtfyNotifier.notify(
        title: "📵 Spam: #{caller}",
        message: spam_message(call),
        priority: "low",
        tags: [ "no_entry", "spam" ],
        url: ntfy_url,
        default_priority: ntfy_priority,
        call: call
      )
    elsif call.status == "unknown"
      NtfyNotifier.notify(
        title: "❓ Sconosciuto: #{caller}",
        message: unknown_message(call),
        priority: "default",
        tags: [ "phone", "question" ],
        url: ntfy_url,
        default_priority: ntfy_priority,
        call: call
      )
    else
      NtfyNotifier.notify(
        title: "📞 Da #{caller}",
        message: legit_message(call),
        priority: "high",
        tags: [ "phone", call.status ],
        url: ntfy_url,
        default_priority: ntfy_priority,
        call: call
      )
    end
  end

  private

  def spam_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << call.ai_summary if call.ai_summary           # one-line TL;DR (P2-3)
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Motivo: #{call.ai_reason}" if call.ai_reason
    parts << "Confidenza: #{call.confidence_pct}%" if call.confidence_pct
    parts.join("\n").strip
  end

  def legit_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << call.ai_summary if call.ai_summary           # one-line TL;DR (P2-3)
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Classificazione: #{call.status}#{ai_confidence_suffix(call)}"
    parts.join("\n").strip
  end

  def unknown_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << "Il chiamante non ha detto nulla."
    parts.join("\n").strip
  end

  def ai_confidence_suffix(call)
    return "" unless call.confidence_pct
    " (#{call.confidence_pct}%)"
  end
end
