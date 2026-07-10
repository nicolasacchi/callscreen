# Persists the screening/voicemail audio to local storage the moment
# recording.saved arrives, decoupled from transcription/classification.
# Telnyx recording URLs are short-lived pre-signed S3 links: when
# ScreeningJob's retries (Whisper outage, transient download failures)
# outlast the link, the voicemail audio is gone forever — observed in prod
# as a terminal "Download failed: HTTP 403" with no local copy, leaving the
# operator a notification pointing at unplayable audio. This job's only work
# is download + persist, so the audio is captured while the URL still works;
# ScreeningJob and RecordingsController then reuse the local file via
# RecordingDownloader's existing-file short-circuit.
class PersistRecordingJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Short fixed waits, not polynomial backoff: the pre-signed URL is expiring
  # while we wait, so minutes-long gaps would defeat the job's purpose.
  retry_on RecordingDownloader::TransientError, wait: 10.seconds, attempts: 6

  def perform(call_id)
    call = Call.find(call_id)
    return if call.recording_url.blank?

    local_path = RecordingDownloader.fetch(call)
    call.update!(recording_local_path: local_path) if call.recording_local_path.blank?
  end
end
