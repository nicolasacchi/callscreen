require "test_helper"

class CleanupRecordingsJobTest < ActiveJob::TestCase
  test "removes recordings older than auto_delete_days and nullifies path" do
    Setting.set("auto_delete_days", "30")

    old_path = Rails.root.join("storage/recordings/old-cleanup-test.wav")
    FileUtils.mkdir_p(old_path.dirname)
    File.binwrite(old_path, "old wav")

    old_call = Call.create!(
      call_sid: "old-cleanup-test",
      from_number: "+390000000000",
      status: :completed,
      recording_local_path: old_path.to_s,
      created_at: 60.days.ago
    )

    new_path = Rails.root.join("storage/recordings/recent-cleanup-test.wav")
    File.binwrite(new_path, "recent wav")
    new_call = Call.create!(
      call_sid: "recent-cleanup-test",
      from_number: "+390000000001",
      status: :completed,
      recording_local_path: new_path.to_s,
      created_at: 5.days.ago
    )

    CleanupRecordingsJob.new.perform

    assert_not File.exist?(old_path), "old recording should have been deleted"
    assert_nil old_call.reload.recording_local_path

    assert File.exist?(new_path), "recent recording should still exist"
    assert_equal new_path.to_s, new_call.reload.recording_local_path
  ensure
    FileUtils.rm_f(old_path) if defined?(old_path)
    FileUtils.rm_f(new_path) if defined?(new_path)
  end
end
