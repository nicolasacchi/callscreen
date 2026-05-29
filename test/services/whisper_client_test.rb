require "test_helper"

class WhisperClientTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join("tmp", "whisper_client_test.wav")
    File.binwrite(@path, "RIFFdummy")
    @url = "#{ENV['WHISPER_API_URL']}/v1/audio/transcriptions"
  end

  teardown { FileUtils.rm_f(@path) }

  test "returns transcript text on success" do
    stub_request(:post, @url).to_return(status: 200, body: { text: "ciao" }.to_json)
    assert_equal "ciao", WhisperClient.new(@path, language: "it").transcribe
  end

  test "returns empty string when the caller said nothing (successful empty transcription)" do
    stub_request(:post, @url).to_return(status: 200, body: { text: "" }.to_json)
    assert_equal "", WhisperClient.new(@path).transcribe
  end

  test "raises TransportError on a 5xx so the job retries instead of misclassifying" do
    stub_request(:post, @url).to_return(status: 503, body: "service unavailable")
    assert_raises(WhisperClient::TransportError) { WhisperClient.new(@path).transcribe }
  end

  test "raises TransportError on a connection timeout" do
    stub_request(:post, @url).to_timeout
    assert_raises(WhisperClient::TransportError) { WhisperClient.new(@path).transcribe }
  end

  test "raises TransportError on an unparseable success body" do
    stub_request(:post, @url).to_return(status: 200, body: "<<not json>>")
    assert_raises(WhisperClient::TransportError) { WhisperClient.new(@path).transcribe }
  end

  test "clamps an unsupported language to it" do
    captured = nil
    stub_request(:post, @url)
      .with { |req| captured = req.body.to_s; true }
      .to_return(status: 200, body: { text: "x" }.to_json)
    WhisperClient.new(@path, language: "fr").transcribe
    assert_match(/name="language"\r?\n\r?\nit\b/m, captured)
  end
end
