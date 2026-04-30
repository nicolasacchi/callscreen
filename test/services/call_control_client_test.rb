require "test_helper"

class CallControlClientTest < ActiveSupport::TestCase
  CCID = "v3:fNH_WFrYaoJ9OBJxftOOvPWhWddhomD3CjtzNSmKXZENKdquIE-i1Q"

  setup do
    @client = CallControlClient.new(api_key: "test-key", app_domain: "https://phone.test")
  end

  def stub_action(action, body_match: nil)
    stub = stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/#{action}")
           .with(headers: { "Authorization" => "Bearer test-key", "Content-Type" => "application/json" })
    stub = stub.with(body: body_match) if body_match
    stub.to_return(status: 200, body: '{"data":{"result":"ok"}}', headers: { "Content-Type" => "application/json" })
  end

  test "answer issues POST /actions/answer with empty body" do
    s = stub_action(:answer, body_match: "{}")
    result = @client.answer(CCID)
    assert result[:ok]
    assert_requested s
  end

  test "reject issues POST /actions/reject with cause" do
    s = stub_action(:reject, body_match: hash_including(cause: "USER_BUSY"))
    @client.reject(CCID)
    assert_requested s
  end

  test "hangup issues POST /actions/hangup" do
    s = stub_action(:hangup)
    @client.hangup(CCID)
    assert_requested s
  end

  test "playback_start posts the audio_url" do
    s = stub_action(:playback_start, body_match: hash_including(audio_url: "https://phone.test/g.wav"))
    @client.playback_start(CCID, audio_url: "https://phone.test/g.wav")
    assert_requested s
  end

  test "speak posts payload + voice + language" do
    s = stub_action(:speak, body_match: hash_including(payload: "Ciao", voice: "alice", language: "it-IT"))
    @client.speak(CCID, payload: "Ciao")
    assert_requested s
  end

  test "gather_using_audio posts transcription parameters" do
    s = stub_action(:gather_using_audio, body_match: hash_including(
      audio_url: "https://phone.test/g.wav",
      transcription: true,
      transcription_engine: "Google",
      language: "it-IT"
    ))
    @client.gather_using_audio(CCID, audio_url: "https://phone.test/g.wav")
    assert_requested s
  end

  test "gather_using_speak posts payload + transcription parameters" do
    s = stub_action(:gather_using_speak, body_match: hash_including(
      payload: "Buongiorno", transcription: true, transcription_engine: "Google"
    ))
    @client.gather_using_speak(CCID, payload: "Buongiorno")
    assert_requested s
  end

  test "record_start posts format/max_length/beep" do
    s = stub_action(:record_start, body_match: hash_including(format: "wav", max_length: 120, play_beep: true))
    @client.record_start(CCID, max_length: 120)
    assert_requested s
  end

  test "transfer posts to + timeout_secs" do
    s = stub_action(:transfer, body_match: hash_including(to: "+393990000001", timeout_secs: 15))
    @client.transfer(CCID, to: "+393990000001")
    assert_requested s
  end

  test "passes X-Request-ID header from Current.request_id" do
    Current.request_id = "req-abc-123"
    s = stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/hangup")
        .with(headers: { "X-Request-ID" => "req-abc-123" })
        .to_return(status: 200)
    @client.hangup(CCID)
    assert_requested s
  ensure
    Current.request_id = nil
  end

  test "swallows errors and returns ok: false instead of raising" do
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/hangup").to_raise(Errno::ECONNREFUSED)
    result = @client.hangup(CCID)
    refute result[:ok]
    assert result[:error]
  end

  test "logs and reports a non-2xx response without raising" do
    stub_request(:post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/hangup").to_return(status: 422, body: '{"errors":[]}')
    result = @client.hangup(CCID)
    refute result[:ok]
    assert_equal 422, result[:status]
  end

  test "returns ok: false when api_key is empty" do
    bare = CallControlClient.new(api_key: "")
    result = bare.hangup(CCID)
    refute result[:ok]
    assert_match(/api key/, result[:error])
  end

  test "returns ok: false when call_control_id is empty" do
    result = @client.hangup("")
    refute result[:ok]
    assert_match(/call_control_id/, result[:error])
  end
end
