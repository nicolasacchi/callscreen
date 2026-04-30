class TranscribeRecordingJob < ApplicationJob
  # Hosts where Telnyx legitimately serves recording URLs.
  # - *.telnyx.com:        their API endpoints (used during call control)
  # - s3.amazonaws.com:    legacy path-style for the telephony-recorder S3 bucket
  # - *.s3.amazonaws.com:  virtual-hosted style (e.g. telephony-recorder-prod.s3.amazonaws.com)
  # - *.s3.<region>.amazonaws.com: region-specific S3 endpoints
  # AWS pre-signed URLs carry their own auth in query params; we don't add
  # the TELNYX_API_KEY header to S3 hosts to avoid leaking it.
  TRUSTED_HOST_PATTERNS = [
    /\A[a-z0-9.-]+\.telnyx\.com\z/i,
    /\As3\.amazonaws\.com\z/i,
    /\A[a-z0-9.-]+\.s3\.amazonaws\.com\z/i,
    /\A[a-z0-9.-]+\.s3\.[a-z0-9-]+\.amazonaws\.com\z/i
  ].freeze

  TELNYX_API_HOST = /\A[a-z0-9.-]+\.telnyx\.com\z/i

  queue_as :default
  discard_on ActiveRecord::RecordNotFound
  retry_on Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error,
           wait: :polynomially_longer, attempts: 3

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
      tags: [ "phone", "voicemail" ]
    )
    call.update!(notified_at: Time.current)
  rescue => e
    Rails.logger.error("TranscribeRecordingJob failed for call #{call_id} (#{e.class.name})")
    call&.update!(status: :failed)
    NtfyNotifier.notify(
      title: "Transcription failed",
      message: "Call #{call_id} failed transcription (#{e.class.name})",
      priority: "high",
      tags: [ "warning" ]
    )
    raise
  end

  private

  def download_recording(call)
    dir = Rails.root.join("storage", "recordings")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{call.call_sid}.wav")
    expanded = File.expand_path(path)
    raise "Path traversal blocked for call_sid #{call.call_sid.inspect}" \
      unless expanded.start_with?(dir.to_s + "/")

    uri = URI.parse(call.recording_url.to_s)
    raise "Invalid recording URL host: #{uri.host.inspect}" \
      unless uri.host && TRUSTED_HOST_PATTERNS.any? { |re| uri.host.match?(re) }

    headers = {}
    # Only attach the Telnyx API key when the host is actually Telnyx's API.
    # S3 pre-signed URLs already carry auth in their query string; sending the
    # header anywhere else would leak it.
    if uri.host.match?(TELNYX_API_HOST) && ENV["TELNYX_API_KEY"].present?
      headers["Authorization"] = "Bearer #{ENV['TELNYX_API_KEY']}"
    end

    response = HTTParty.get(call.recording_url, headers: headers, timeout: 60)
    raise "Download failed: HTTP #{response.code}" unless response.success?

    File.binwrite(expanded, response.body)
    expanded
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
