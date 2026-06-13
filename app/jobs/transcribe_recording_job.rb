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
    call&.update!(status: :failed)
    NtfyNotifier.notify(
      title: "Transcription failed",
      message: "Call #{call_id} failed transcription (#{error.class.name})",
      priority: "high",
      tags: [ "warning" ],
      url: call&.tenant&.ntfy_url,
      default_priority: call&.tenant&.ntfy_priority
    )
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

    # Skip ntfy push if the call was already notified (e.g. by NotifyJob for
    # the spam-confirmed path, or a duplicate run of this job).
    unless call.notified_at?
      NtfyNotifier.notify(
        title: notification_title(call),
        message: build_message(call, transcript),
        priority: "high",
        tags: [ "phone", call.status.to_s ]
      )
      call.update!(notified_at: Time.current)
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
      conf = call.ai_confidence
      suffix = conf ? " (#{(conf.to_f * 100).round}%)" : ""
      parts << ""
      parts << "Classificazione: #{call.status}#{suffix}"
    end
    parts.join("\n").strip
  end
end
