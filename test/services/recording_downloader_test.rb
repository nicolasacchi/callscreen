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

  # --- existing-file short-circuit (URL-expiry resilience) ---

  test "returns the already-persisted file without re-downloading" do
    # PersistRecordingJob may have saved the audio before ScreeningJob runs;
    # by then the pre-signed URL can be expired (403), so a re-download must
    # not even be attempted.
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    path = Rails.root.join("storage/recordings/rd-test-1.wav")
    File.binwrite(path, "WAV-ON-DISK")

    assert_equal path.to_s, RecordingDownloader.fetch(@call)
    assert_not_requested :get, /./
  end

  test "an empty (partial-write) file does not short-circuit the download" do
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    path = Rails.root.join("storage/recordings/rd-test-1.wav")
    FileUtils.touch(path)
    stub_request(:get, @call.recording_url).to_return(status: 200, body: "WAV")

    RecordingDownloader.fetch(@call)

    assert_equal "WAV", File.binread(path)
  end

  # --- SSRF via redirect (SEC-3) ---

  test "does not follow redirects; a 30x from a trusted host is a hard failure" do
    # A trusted-host 302 → internal target must NOT be followed (that would
    # re-send the Telnyx bearer header cross-host and reach internal services).
    @call.update!(recording_url: "https://api.telnyx.com/v2/recordings/rec.wav")
    internal = stub_request(:get, "http://169.254.169.254/latest/meta-data/")
                 .to_return(status: 200, body: "SECRET")
    stub_request(:get, @call.recording_url)
      .to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest/meta-data/" })

    err = assert_raises(RuntimeError) { RecordingDownloader.fetch(@call) }
    assert_not_kind_of RecordingDownloader::TransientError, err, "a redirect is permanent, not retryable"
    # The redirect target must never be fetched (no header re-send, no SSRF hop).
    assert_not_requested internal
  end
end
