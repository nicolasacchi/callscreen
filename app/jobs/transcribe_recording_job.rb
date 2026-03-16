class TranscribeRecordingJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(call_id)
    call = Call.find(call_id)

    local_path = download_recording(call)
    call.update!(recording_local_path: local_path)

    transcript = WhisperClient.new(local_path).transcribe
    call.update!(
      voicemail_transcript: transcript || "[transcription failed]",
      status: :completed
    )

    NtfyNotifier.notify(
      title: "Voicemail: #{call.contact_name}",
      message: build_message(call, transcript),
      priority: "high",
      tags: ["phone", "voicemail"]
    )
    call.update!(notified_at: Time.current)
  rescue => e
    Rails.logger.error("TranscribeRecordingJob failed for call #{call_id}: #{e.message}")
    call&.update!(status: :failed)
    NtfyNotifier.notify(
      title: "Transcription failed: #{call&.from_number}",
      message: "Call #{call_id}: #{e.message}",
      priority: "high",
      tags: ["warning"]
    )
    raise
  end

  private

  def download_recording(call)
    dir = Rails.root.join("storage", "recordings")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{call.call_sid}.wav")

    headers = {}
    headers["Authorization"] = "Bearer #{ENV['TELNYX_API_KEY']}" if ENV["TELNYX_API_KEY"].present?

    response = HTTParty.get(call.recording_url, headers: headers, timeout: 60)
    raise "Download failed: HTTP #{response.code}" unless response.success?

    File.binwrite(path, response.body)
    path.to_s
  end

  def build_message(call, transcript)
    parts = []
    parts << "From: #{call.from_number}"
    parts << "Contact: #{call.contact&.name}" if call.contact&.name.present?
    parts << "Duration: #{call.duration_seconds}s" if call.duration_seconds
    parts << ""
    if call.screening_transcript.present?
      parts << "Screening: #{call.screening_transcript}"
      parts << ""
    end
    parts << "Message: #{transcript || '[transcription failed]'}"
    parts.join("\n")
  end
end
