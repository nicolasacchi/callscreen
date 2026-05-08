class NotifyJob < ApplicationJob
  queue_as :default
  # Absorbs the race where a Call is destroyed (e.g. by e2e teardown,
  # or operator manual delete) between ScreeningJob's enqueue and our
  # perform. Without this the job retries until the dead set, polluting
  # SolidQueue with no value.
  discard_on ActiveRecord::RecordNotFound

  def perform(call_id)
    call = Call.find(call_id)
    return if call.notified_at.present?

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

    call.update!(notified_at: Time.current)
  end

  private

  def spam_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Motivo: #{call.ai_reason}" if call.ai_reason
    parts << "Confidenza: #{(call.ai_confidence.to_f * 100).round}%" if call.ai_confidence
    parts.join("\n").strip
  end

  def legit_message(call)
    parts = []
    parts << "Da: #{call.from_number}"
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
    return "" unless call.ai_confidence
    " (#{(call.ai_confidence.to_f * 100).round}%)"
  end
end
