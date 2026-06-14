class TranscribeRecordingJob < ApplicationJob
  include RetryableTransport  # provides RETRYABLE (shared transient transport errors)

  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: 4) do |job, error|
    report_failure(job.arguments.first, error)
  end

  def self.report_failure(call_id, error)
    Rails.logger.error("TranscribeRecordingJob failed for call #{call_id} (#{error.class.name})")
    Sentry.capture_exception(error) if defined?(Sentry)
    call = Call.find_by(id: call_id)
    return unless call
    # Idempotent: a success push (or a prior failure push) already claimed the
    # call — never double-alert or overwrite a delivered disposition.
    return if call.notified_at?

    if call.recording_local_path.present?
      # We have the downloaded audio — only transcription failed (e.g. a Whisper
      # outage). Degrade to a voicemail the operator can still listen to via the
      # authenticated recording playback, not a dead :failed (P2-5).
      call.update!(status: :voicemail) unless %w[voicemail completed].include?(call.status)
      return if Call.where(id: call.id, notified_at: nil).update_all(notified_at: Time.current).zero?
      NtfyNotifier.notify(
        title: "📨 Messaggio vocale da #{call.contact_name}",
        message: "Da: #{call.from_number}\nTrascrizione non disponibile — ascolta la registrazione nell'app.",
        priority: "high", tags: [ "envelope_with_arrow" ],
        url: call.tenant&.ntfy_url, tenant_priority: call.tenant&.ntfy_priority, call: call
      )
    else
      # No audio downloaded — nothing to listen to, so :failed is correct.
      call.update!(status: :failed) unless call.status == "completed"
      return if Call.where(id: call.id, notified_at: nil).update_all(notified_at: Time.current).zero?
      NtfyNotifier.notify(
        title: "⚠️ Trascrizione non riuscita",
        message: "Chiamata da #{call.from_number} — trascrizione non riuscita (#{error.class.name}).",
        priority: "high", tags: [ "warning" ],
        url: call.tenant&.ntfy_url, tenant_priority: call.tenant&.ntfy_priority
      )
    end
  end

  def perform(call_id)
    call = Call.find(call_id)

    local_path = RecordingDownloader.fetch(call)
    call.update!(recording_local_path: local_path)

    transcript = WhisperClient.new(local_path).transcribe
    call.update!(
      voicemail_transcript: transcript || "[transcription failed]",
      status: :completed
    )

    # Atomic claim mirrors NotifyJob: exactly one push per call, race-safe
    # against NotifyJob (spam-confirmed path) and any duplicate/retried run.
    # Routes through the tenant's ntfy_url (honouring the 'disabled' opt-out)
    # and carries the action buttons, like every other notify site.
    if Call.where(id: call.id, notified_at: nil).update_all(notified_at: Time.current).positive?
      NtfyNotifier.notify(
        title: notification_title(call),
        message: build_message(call, transcript),
        priority: "high",
        tags: [ "phone", call.status.to_s ],
        url: call.tenant&.ntfy_url,
        tenant_priority: call.tenant&.ntfy_priority,
        call: call
      )
    end
  rescue *RETRYABLE
    raise # defer to retry_on; report_failure runs once on exhaustion
  rescue => e
    self.class.report_failure(call_id, e)
    raise
  end

  private

  def notification_title(call)
    duration = call.duration_seconds.to_i
    suffix = duration.positive? ? " (#{duration}s)" : ""
    "📞 Da #{call.contact_name}#{suffix}"
  end

  def build_message(call, transcript)
    parts = []
    parts << "Da: #{call.from_number}"
    if transcript.present?
      parts << "Messaggio: «#{transcript.strip}»"
    else
      parts << "Messaggio: [trascrizione non disponibile]"
    end
    if call.screening_transcript.present? && call.screening_transcript != transcript
      parts << ""
      cleaned = call.screening_transcript.strip.gsub(/\n?\[Clarification\]:\s*/, " — ")
      parts << "Detto: «#{cleaned}»"
    end
    if call.ai_classification.present?
      suffix = call.confidence_pct ? " (#{call.confidence_pct}%)" : ""
      parts << ""
      parts << "Classificazione: #{call.status}#{suffix}"
    end
    parts.join("\n").strip
  end
end
