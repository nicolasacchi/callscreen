class NotifyJob < ApplicationJob
  queue_as :default

  def perform(call_id)
    call = Call.find(call_id)
    return if call.notified_at.present?

    tenant = call.tenant
    ntfy_url      = tenant&.ntfy_url
    ntfy_priority = tenant&.ntfy_priority

    if call.spam?
      NtfyNotifier.notify(
        title: "📵 Spam: #{call.from_number}",
        message: spam_message(call),
        priority: "low",
        tags: [ "no_entry", "spam" ],
        url: ntfy_url,
        default_priority: ntfy_priority
      )
    else
      NtfyNotifier.notify(
        title: "📞 Da #{call.from_number}",
        message: legit_message(call),
        priority: "high",
        tags: [ "phone", call.status ],
        url: ntfy_url,
        default_priority: ntfy_priority
      )
    end

    call.update!(notified_at: Time.current)
  end

  private

  def spam_message(call)
    parts = []
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Motivo: #{call.ai_reason}" if call.ai_reason
    parts << "Confidenza: #{(call.ai_confidence.to_f * 100).round}%" if call.ai_confidence
    parts.join("\n").strip
  end

  def legit_message(call)
    parts = []
    parts << "Contatto: #{call.contact.name}" if call.contact&.name.present?
    parts << "«#{call.screening_transcript.strip}»" if call.screening_transcript.present?
    parts << ""
    parts << "Classificazione: #{call.status}#{ai_confidence_suffix(call)}"
    parts.join("\n").strip
  end

  def ai_confidence_suffix(call)
    return "" unless call.ai_confidence
    " (#{(call.ai_confidence.to_f * 100).round}%)"
  end
end
