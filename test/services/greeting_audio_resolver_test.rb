require "test_helper"

class GreetingAudioResolverTest < ActiveSupport::TestCase
  setup { @paths = [] }
  teardown { @paths.each { |p| FileUtils.rm_f(p) } }

  def render!(slug, voice, tone)
    path = GreetingsStorage.path_for(slug, voice, tone)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "RIFF dummy")
    @paths << path
    path
  end

  test "url_for_voice returns nil when no rendered WAV exists" do
    assert_nil GreetingAudioResolver.url_for_voice(slug: "gar_test", voice: "im_nicola", tone: "natural")
  end

  test "url_for_voice builds the public URL when the WAV exists" do
    render!("gar_test", "im_nicola", "natural")
    url = GreetingAudioResolver.url_for_voice(slug: "gar_test", voice: "im_nicola", tone: "natural")
    assert_match %r{/greetings/gar_test/im_nicola/natural\.wav\z}, url
  end

  test "url_for_voice rejects an unsafe path component (no traversal)" do
    assert_nil GreetingAudioResolver.url_for_voice(slug: "../etc/passwd", voice: "im_nicola", tone: "natural")
  end

  test "url_for_voice signs cloned-voice URLs" do
    render!("gar_test", "_t1", "natural")
    url = GreetingAudioResolver.url_for_voice(slug: "gar_test", voice: "_t1", tone: "natural")
    assert_includes url, "?sig="
  end
end
