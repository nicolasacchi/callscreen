require "test_helper"

class GreetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @slug = "informal_tu"
    @voice = "if_sara"
    @path = Rails.root.join("storage/greetings", @slug, "#{@voice}.wav")
    FileUtils.mkdir_p(@path.dirname)
    File.binwrite(@path, "RIFF dummy wav data")
  end

  teardown do
    FileUtils.rm_f(@path)
  end

  test "serves the audio file when slug + voice + file exist" do
    get greeting_url(slug: @slug, voice: @voice)
    assert_response :success
    assert_equal "audio/wav", @response.media_type
  end

  test "returns 404 when the audio file is missing" do
    FileUtils.rm_f(@path)
    get greeting_url(slug: @slug, voice: @voice)
    assert_response :not_found
  end

  test "returns 404 when slug is not in the catalog" do
    get "/greetings/not_a_slug/#{@voice}.wav"
    assert_response :not_found
  end

  test "returns 404 when voice is not in the allowlist" do
    get "/greetings/#{@slug}/Polly.Carla.wav"
    assert_response :not_found
  end
end
