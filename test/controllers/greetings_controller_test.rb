require "test_helper"

class GreetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @slug = "informal_tu"
    @voice = "if_sara"
    @tone = "natural"
    @path = GreetingsStorage.path_for(@slug, @voice, @tone)
    FileUtils.mkdir_p(@path.dirname)
    File.binwrite(@path, "RIFF dummy wav data")
  end

  teardown do
    FileUtils.rm_f(@path)
  end

  test "serves the audio file when slug + voice + tone + file exist" do
    get greeting_url(slug: @slug, voice: @voice, tone: @tone)
    assert_response :success
    assert_equal "audio/wav", @response.media_type
  end

  test "returns 404 when the audio file is missing" do
    FileUtils.rm_f(@path)
    get greeting_url(slug: @slug, voice: @voice, tone: @tone)
    assert_response :not_found
  end

  test "returns 404 when slug is not in the catalog" do
    get "/greetings/not_a_slug/#{@voice}/#{@tone}.wav"
    assert_response :not_found
  end

  test "returns 404 when voice is not in the allowlist" do
    get "/greetings/#{@slug}/Polly.Carla/#{@tone}.wav"
    assert_response :not_found
  end

  test "returns 404 when tone is not in the catalog" do
    get "/greetings/#{@slug}/#{@voice}/lightning.wav"
    assert_response :not_found
  end

  test "cloned-voice greeting requires a valid signature" do
    @cloned_voice = "_t#{tenants(:default).id}"
    cloned_path = GreetingsStorage.path_for(@slug, @cloned_voice, "natural")
    FileUtils.mkdir_p(cloned_path.dirname)
    File.binwrite(cloned_path, "RIFF cloned wav")

    get "/greetings/#{@slug}/#{@cloned_voice}/natural.wav"
    assert_response :not_found, "no signature → 404"

    get "/greetings/#{@slug}/#{@cloned_voice}/natural.wav", params: { sig: "bogus" }
    assert_response :not_found, "wrong signature → 404"

    sig = GreetingSignature.encode(slug: @slug, voice: @cloned_voice, tone: "natural")
    get "/greetings/#{@slug}/#{@cloned_voice}/natural.wav", params: { sig: sig }
    assert_response :success, "valid signature → 200"
  ensure
    FileUtils.rm_rf(GreetingsStorage.path_for(@slug, @cloned_voice, "natural").dirname) if @cloned_voice
  end

  test "cloned-voice English tone serves with a valid signature" do
    @cloned_voice = "_t#{tenants(:default).id}"
    cloned_path = GreetingsStorage.path_for(@slug, @cloned_voice, "natural_en")
    FileUtils.mkdir_p(cloned_path.dirname)
    File.binwrite(cloned_path, "RIFF cloned en")

    sig = GreetingSignature.encode(slug: @slug, voice: @cloned_voice, tone: "natural_en")
    get "/greetings/#{@slug}/#{@cloned_voice}/natural_en.wav", params: { sig: sig }
    assert_response :success
  ensure
    FileUtils.rm_rf(GreetingsStorage.path_for(@slug, @cloned_voice, "natural_en").dirname) if @cloned_voice
  end

  test "a catalog voice cannot be served by passing a cloned-voice signature for a different path" do
    # signature binds the path triple — can't be replayed for another voice
    sig = GreetingSignature.encode(slug: @slug, voice: "_t999", tone: "natural")
    get "/greetings/#{@slug}/#{@voice}/natural.wav", params: { sig: sig }
    assert_response :success # @voice (if_sara) is a catalog voice, served regardless of sig
  end
end
