class CleanupRecordingsJob < ApplicationJob
  queue_as :default

  def perform
    days = Setting.get("auto_delete_days").to_i
    days = 30 if days <= 0
    cutoff = days.days.ago

    Call.where("recording_local_path IS NOT NULL AND created_at < ?", cutoff).find_each do |call|
      FileUtils.rm_f(call.recording_local_path) if call.recording_local_path.present?
      call.update!(recording_local_path: nil)
    end
  end
end
