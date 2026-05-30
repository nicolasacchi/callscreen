require "test_helper"

class GreetingsStorageTest < ActiveSupport::TestCase
  test "builds a path under ROOT for safe components" do
    path = GreetingsStorage.path_for("informal_tu", "im_nicola", "natural")
    assert path.to_s.start_with?(GreetingsStorage::ROOT.to_s + "/")
    assert path.to_s.end_with?("informal_tu/im_nicola/natural.wav")
  end

  test "accepts cloned-voice dir and english tone suffix" do
    path = GreetingsStorage.path_for("spam_disclose", "_t12", "natural_en")
    assert path.to_s.end_with?("spam_disclose/_t12/natural_en.wav")
  end

  test "raises on path traversal in the voice component" do
    assert_raises(ArgumentError) { GreetingsStorage.path_for("slug", "../../etc", "natural") }
    assert_raises(ArgumentError) { GreetingsStorage.path_for("slug", "/etc/cron.d/x", "natural") }
  end

  test "raises on unsafe slug or tone component" do
    assert_raises(ArgumentError) { GreetingsStorage.path_for("../x", "im_nicola", "natural") }
    assert_raises(ArgumentError) { GreetingsStorage.path_for("slug", "im_nicola", "natural/../..") }
  end

  test "safe_component? accepts voices/slugs/tones and rejects traversal" do
    assert GreetingsStorage.safe_component?("_t12")
    assert GreetingsStorage.safe_component?("natural_en")
    assert GreetingsStorage.safe_component?("informal_tu")
    refute GreetingsStorage.safe_component?("../x")
    refute GreetingsStorage.safe_component?("a/b")
    refute GreetingsStorage.safe_component?("UPPER")
  end
end
