require "set"

class CleanupRecordingsJob < ApplicationJob
  # Runs on :rendering (not :default) so its row-by-row file deletes don't tie
  # up a call-processing worker thread during the nightly run.
  queue_as :rendering

  # Retention windows (both Settings, default 30 days):
  #  - audio recordings        → auto_delete_days
  #  - transcripts + ai_class. → auto_delete_transcripts_days
  # Phone numbers on Call/Contact are kept so blacklist/whitelist Rules keep
  # working; stale caller numbers in audit-log metadata are scrubbed past the
  # transcript window.
  def perform
    delete_audio_recordings
    nullify_transcripts
    sweep_orphan_recordings
    scrub_audit_pii
  end

  private

  def retention_days(key)
    days = Setting.get(key).to_i
    days.positive? ? days : 30
  end

  def delete_audio_recordings
    cutoff = retention_days("auto_delete_days").days.ago
    ids = []
    Call.where(created_at: ..cutoff).where.not(recording_local_path: nil)
        .select(:id, :recording_local_path).find_each do |call|
      FileUtils.rm_f(call.recording_local_path)
      ids << call.id
    end
    # One UPDATE instead of one-per-row, to minimise SQLite write churn.
    Call.where(id: ids).update_all(recording_local_path: nil) if ids.any?
  end

  def nullify_transcripts
    cutoff = retention_days("auto_delete_transcripts_days").days.ago
    Call.where(created_at: ..cutoff)
        .where("voicemail_transcript IS NOT NULL OR screening_transcript IS NOT NULL OR ai_classification IS NOT NULL")
        .in_batches.update_all(
          voicemail_transcript: nil,
          screening_transcript: nil,
          ai_classification: nil
        )
  end

  # Reclaim WAVs on disk that no Call references — e.g. a Call destroyed before
  # its recording, or a job that died after fetch before persisting the path.
  # Bounded by the audio-retention window so in-flight downloads (seconds old)
  # are never touched. Without this, orphaned caller audio (personal data)
  # could linger indefinitely, defeating the stated retention (OPS-7).
  def sweep_orphan_recordings
    cutoff = retention_days("auto_delete_days").days.ago
    dir = Rails.root.join("storage", "recordings")
    return unless dir.exist?
    known = Call.where.not(recording_local_path: nil).pluck(:recording_local_path).to_set
    Dir.glob(dir.join("*.wav")).each do |path|
      next if known.include?(path)
      next unless File.mtime(path) < cutoff
      FileUtils.rm_f(path)
      Rails.logger.info("CleanupRecordingsJob: removed orphan recording #{File.basename(path)}")
    end
  end

  # Audit logs are an immutable trail kept indefinitely, but they should not
  # retain caller phone numbers past the transcript-retention window (DM-6).
  def scrub_audit_pii
    cutoff = retention_days("auto_delete_transcripts_days").days.ago
    AuditLog.where(created_at: ..cutoff)
            .where("metadata LIKE ?", "%from%")
            .find_each do |log|
      meta = log.metadata
      next unless meta.is_a?(Hash) && (meta.key?("from") || meta.key?("from_number"))
      log.update_columns(metadata: meta.except("from", "from_number"))
    end
  end
end
