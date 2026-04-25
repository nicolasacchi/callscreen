class CleanupRecordingsJob < ApplicationJob
  queue_as :default

  # Two retention windows:
  # - audio recordings (auto_delete_days, default 30 days)
  # - transcripts and AI classifications (auto_delete_transcripts_days, default 30)
  # Phone numbers are kept indefinitely so blacklist/whitelist Rules continue
  # to work; rotate or scrub them via a separate manual procedure if needed.
  def perform
    delete_audio_recordings
    nullify_transcripts
  end

  private

  def delete_audio_recordings
    days = Setting.get("auto_delete_days").to_i
    days = 30 if days <= 0
    cutoff = days.days.ago

    Call.where(created_at: ..cutoff).where.not(recording_local_path: nil).find_each do |call|
      FileUtils.rm_f(call.recording_local_path)
      call.update!(recording_local_path: nil)
    end
  end

  def nullify_transcripts
    days = Setting.get("auto_delete_transcripts_days").to_i
    days = 30 if days <= 0
    cutoff = days.days.ago

    Call.where(created_at: ..cutoff)
        .where("voicemail_transcript IS NOT NULL OR screening_transcript IS NOT NULL OR ai_classification IS NOT NULL")
        .find_each do |call|
      call.update!(
        voicemail_transcript: nil,
        screening_transcript: nil,
        ai_classification: nil
      )
    end
  end
end
