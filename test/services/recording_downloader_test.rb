require "test_helper"

class RecordingDownloaderTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @call = @tenant.calls.create!(call_sid: "rd-test-1", from_number: "+390000000000", status: :completed)
  end

  teardown { FileUtils.rm_f(Rails.root.join("storage/recordings/rd-test-1.wav")) }

  # --- SSRF host allowlist ---

  test "rejects an untrusted host" do
    @call.update!(recording_url: "https://evil.example.com/leak.wav")
    assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
  end

  test "rejects a near-miss host (api.telnyx.com.evil.com)" do
    @call.update!(recording_url: "https://api.telnyx.com.evil.com/x.wav")
    assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
  end

  test "rejects the cloud metadata IP" do
    @call.update!(recording_url: "http://169.254.169.254/latest/meta-data/")
    assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
  end

  # --- credential leak prevention ---

  test "does NOT send the Telnyx API key to S3 hosts" do
    @call.update!(recording_url: "https://telephony-recorder.s3.amazonaws.com/rec.wav")
    auth = :unset
    stub_request(:get, @call.recording_url)
      .with { |req| auth = req.headers["Authorization"]; true }
      .to_return(status: 200, body: "WAV")
    RecordingDownloader.fetch(@call)
    assert_nil auth, "Authorization must not be sent to S3"
  end

  test "sends the Telnyx Bearer header to api.telnyx.com" do
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    auth = nil
    stub_request(:get, @call.recording_url)
      .with { |req| auth = req.headers["Authorization"]; true }
      .to_return(status: 200, body: "WAV")
    RecordingDownloader.fetch(@call)
    assert_equal "Bearer #{ENV['TELNYX_API_KEY']}", auth
  end

  # --- path traversal ---

  test "blocks path traversal via call_sid" do
    @call.update_columns(call_sid: "../../../tmp/pwn")
    @call.update_columns(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
  end

  # --- retry classification ---

  test "5xx raises a retryable TransientError" do
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    stub_request(:get, @call.recording_url).to_return(status: 503, body: "")
    assert_raises(RecordingDownloader::TransientError) { RecordingDownloader.fetch(@call) }
  end

  test "404 raises a non-retryable error" do
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    stub_request(:get, @call.recording_url).to_return(status: 404, body: "")
    err = assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
    assert_not_kind_of RecordingDownloader::TransientError, err
  end
end
