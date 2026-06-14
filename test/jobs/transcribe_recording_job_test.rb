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

  test "rejects untrusted recording URL host (SSRF guard)" do
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

  test "accepts Telnyx's S3 recording URLs" do
    s3_url = "https://s3.amazonaws.com/telephony-recorder-prod/abc/recording.mp3?X-Amz-Signature=xyz"
    @call.update!(recording_url: s3_url)
    stub_request(:get, s3_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 200, body: { text: "ciao" }.to_json)
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    perform_enqueued_jobs do
      TranscribeRecordingJob.perform_later(@call.id)
    end

    @call.reload
    assert_equal "completed", @call.status
    assert_equal "ciao", @call.voicemail_transcript
  ensure
    expected = Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s
    FileUtils.rm_f(expected)
  end

  test "does NOT send TELNYX_API_KEY to S3 hosts (auth leakage guard)" do
    s3_url = "https://telephony-recorder-prod.s3.amazonaws.com/abc/recording.mp3?X-Amz-Signature=xyz"
    @call.update!(recording_url: s3_url)
    stub_request(:get, s3_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 200, body: { text: "x" }.to_json)
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    perform_enqueued_jobs do
      TranscribeRecordingJob.perform_later(@call.id)
    end

    # Authorization header must NOT contain the Telnyx key when fetching S3
    assert_requested :get, s3_url do |req|
      !req.headers.key?("Authorization") ||
        !req.headers["Authorization"].include?(ENV["TELNYX_API_KEY"])
    end
  ensure
    expected = Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s
    FileUtils.rm_f(expected)
  end

  test "DOES send TELNYX_API_KEY to telnyx.com hosts" do
    telnyx_url = "https://api.telnyx.com/v2/recordings/abc/download.wav"
    @call.update!(recording_url: telnyx_url)
    stub_request(:get, telnyx_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 200, body: { text: "x" }.to_json)
    stub_request(:post, @ntfy_url).to_return(status: 200, body: "")

    perform_enqueued_jobs do
      TranscribeRecordingJob.perform_later(@call.id)
    end

    assert_requested :get, telnyx_url,
                     headers: { "Authorization" => "Bearer #{ENV['TELNYX_API_KEY']}" }
  ensure
    expected = Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s
    FileUtils.rm_f(expected)
  end

  test "Whisper transport failure raises (retryable, deferred to retry — not silently completed)" do
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 500, body: "internal error")

    # A Whisper outage now raises TransportError so the job retries, instead
    # of silently marking the voicemail "completed" with placeholder text.
    assert_raises(WhisperClient::TransportError) do
      TranscribeRecordingJob.new.perform(@call.id)
    end
    assert_not_equal "completed", @call.reload.status
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

  test "voicemail push routes to the tenant's ntfy_url and carries action buttons" do
    @call.tenant.update!(ntfy_url: "https://ntfy.example.test/tenant-topic")
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "FAKE_WAV")
    stub_request(:post, @whisper_url).to_return(status: 200, body: { text: "ciao" }.to_json)
    stub_request(:post, "https://ntfy.example.test/tenant-topic").to_return(status: 200)

    perform_enqueued_jobs { TranscribeRecordingJob.perform_later(@call.id) }

    assert_requested :post, "https://ntfy.example.test/tenant-topic" do |req|
      req.headers["Actions"].to_s.include?("/whitelist")
    end
    assert_not_requested :post, @ntfy_url # NOT the ENV default
  ensure
    FileUtils.rm_f(Rails.root.join("storage/recordings/#{@call.call_sid}.wav").to_s)
  end

  test "report_failure degrades to :voicemail with a listen-in-app push when audio was downloaded" do
    @call.update!(recording_local_path: Rails.root.join("storage/recordings/x.wav").to_s, notified_at: nil)
    stub_request(:post, @ntfy_url).to_return(status: 200)

    TranscribeRecordingJob.report_failure(@call.id, WhisperClient::TransportError.new("whisper down"))

    assert_equal "voicemail", @call.reload.status
    assert_requested :post, @ntfy_url do |req|
      req.headers["Title"].to_s.include?("Messaggio vocale") &&
        req.body.to_s.include?("ascolta la registrazione")
    end
  end
end
