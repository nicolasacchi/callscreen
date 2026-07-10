require "test_helper"

class PersistRecordingJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @call = @tenant.calls.create!(call_sid: "prj-test-1", call_control_id: "prj-test-1",
                                  from_number: "+390000000010", status: :screening,
                                  recording_url: "https://api.telnyx.com/v2/recordings/prj.wav")
    @path = Rails.root.join("storage/recordings/prj-test-1.wav")
  end

  teardown { FileUtils.rm_f(@path) }

  test "downloads the recording and records the local path" do
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "WAV")

    PersistRecordingJob.perform_now(@call.id)

    assert File.exist?(@path)
    assert_equal @path.to_s, @call.reload.recording_local_path
  end

  test "no-op when the call has no recording_url" do
    @call.update!(recording_url: nil)
    PersistRecordingJob.perform_now(@call.id)
    assert_not_requested :get, /./
  end

  test "does not overwrite a recording_local_path already set by ScreeningJob" do
    @call.update!(recording_local_path: "/rails/storage/recordings/already.wav")
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "WAV")

    PersistRecordingJob.perform_now(@call.id)

    assert_equal "/rails/storage/recordings/already.wav", @call.reload.recording_local_path
  end

  test "transient download failure is retried, not dead-lettered" do
    stub_request(:get, @call.recording_url).to_return(status: 503, body: "")

    assert_enqueued_with(job: PersistRecordingJob, args: [ @call.id ]) do
      PersistRecordingJob.perform_now(@call.id)
    end
  end

  test "destroyed call is discarded silently" do
    id = @call.id
    @call.destroy!
    assert_nothing_raised { PersistRecordingJob.perform_now(id) }
  end
end
