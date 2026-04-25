class NotifyJob < ApplicationJob
  queue_as :default

  def perform(call_id)
    call = Call.find(call_id)
    return if call.notified_at.present?

    if call.spam?
      NtfyNotifier.notify(
        title: "Spam: #{call.from_number}",
        message: spam_message(call),
        priority: "low",
        tags: [ "no_entry", "spam" ]
      )
    else
      NtfyNotifier.notify(
        title: "Call: #{call.contact_name}",
        message: legit_message(call),
        priority: "high",
        tags: [ "phone", call.status ]
      )
    end

    call.update!(notified_at: Time.current)
  end

  private

  def spam_message(call)
    parts = [ "From: #{call.from_number}" ]
    parts << "Reason: #{call.ai_reason}" if call.ai_reason
    parts << "Said: #{call.screening_transcript}" if call.screening_transcript.present?
    parts.join("\n")
  end

  def legit_message(call)
    parts = [ "From: #{call.from_number}" ]
    parts << "Contact: #{call.contact&.name}" if call.contact&.name.present?
    parts << "Said: #{call.screening_transcript}" if call.screening_transcript.present?
    parts << "Classification: #{call.ai_reason}" if call.ai_reason
    parts.join("\n")
  end
end
