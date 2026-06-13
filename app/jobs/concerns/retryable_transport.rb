# The shared set of transient transport errors that the recording → Whisper
# jobs retry rather than dead-letter (CQ-6). ScreeningJob and
# TranscribeRecordingJob both raise these from the download/transcribe path; a
# 5xx/429/timeout is transient, so retry with backoff instead of committing a
# wrong disposition. The terminal-failure handlers stay per-job (they diverge:
# ScreeningJob degrades to a voicemail, Transcribe marks :failed).
module RetryableTransport
  RETRYABLE = [
    Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error,
    WhisperClient::TransportError, RecordingDownloader::TransientError
  ].freeze
end
