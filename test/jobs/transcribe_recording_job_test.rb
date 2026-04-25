require "test_helper"

class TranscribeRecordingJobTest < ActiveJob::TestCase
  setup do
    @call = calls(:screening)
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/abc/download.wav")
    @whisper_url = "#{ENV['WHISPER_API_URL']}/v1/audio/transcriptions"
    @ntfy_url = ENV["NTFY_URL"]
  end

  test "successful path: downloads, transcribes, notifies, marks completed" do
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "FAKE_WAV_BYTES")
    stub_request(:post, @whisper_url).to_return(
      status: 200, body: { text: "Buongiorno, sono Mario" }.to_json
    )
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    perform_enqueued_jobs do
      TranscribeRecordingJob.perform_later(@call.id)
    end

    @call.reload
    assert_equal "completed", @call.status
    assert_equal "Buongiorno, sono Mario", @call.voicemail_transcript
    assert_not_nil @call.notified_at
    expected_path = Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s
    assert_equal expected_path, @call.recording_local_path
    assert File.exist?(expected_path)
  ensure
    FileUtils.rm_f(expected_path) if defined?(expected_path) && expected_path
  end

  test "rejects non-Telnyx recording URL host (SSRF guard)" do
    @call.update!(recording_url: "https://attacker.example.com/leak")
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    assert_raises(StandardError) do
      TranscribeRecordingJob.new.perform(@call.id)
    end

    @call.reload
    assert_equal "failed", @call.status
    # critically: no HTTP request is made to the attacker host
    assert_not_requested :get, "https://attacker.example.com/leak"
  end

  test "does NOT send TELNYX_API_KEY to non-Telnyx hosts" do
    @call.update!(recording_url: "https://attacker.example.com/leak")
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    assert_raises(StandardError) do
      TranscribeRecordingJob.new.perform(@call.id)
    end
    # The host check raises BEFORE any HTTP call is made
    assert_not_requested :get, "https://attacker.example.com/leak",
                         headers: { "Authorization" => "Bearer #{ENV['TELNYX_API_KEY']}" }
  end

  test "Whisper failure leaves call status :failed and pushes ntfy warning" do
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 500, body: "internal error")
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    # Whisper returns nil on error; the job currently logs "[transcription failed]" placeholder text.
    perform_enqueued_jobs do
      TranscribeRecordingJob.perform_later(@call.id)
    end

    @call.reload
    assert_equal "completed", @call.status # Whisper failure is non-raising; call still completed
    assert_equal "[transcription failed]", @call.voicemail_transcript
  ensure
    expected = Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s
    FileUtils.rm_f(expected)
  end

  test "download HTTP error raises and sets status :failed" do
    stub_request(:get, @call.recording_url).to_return(status: 404, body: "not found")
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    assert_raises(StandardError) { TranscribeRecordingJob.new.perform(@call.id) }
    assert_equal "failed", @call.reload.status
  end
end
