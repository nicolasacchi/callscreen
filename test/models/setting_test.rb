require "test_helper"

class SettingTest < ActiveSupport::TestCase
  test "get returns persisted value when set" do
    Setting.set("greeting_voice", "Polly.Bianca")
    assert_equal "Polly.Bianca", Setting.get("greeting_voice")
  end

  test "get falls back to DEFAULTS when not persisted" do
    Setting.where(key: "spam_sensitivity").destroy_all
    assert_equal "0.5", Setting.get("spam_sensitivity")
  end

  test "set creates a new row and updates an existing one" do
    Setting.where(key: "auto_delete_days").destroy_all
    Setting.set("auto_delete_days", "60")
    assert_equal "60", Setting.find_by(key: "auto_delete_days").value
    Setting.set("auto_delete_days", "90")
    assert_equal "90", Setting.find_by(key: "auto_delete_days").value
  end

  test "all_with_defaults returns DEFAULTS overlaid with stored values" do
    Setting.where(key: "spam_sensitivity").destroy_all
    Setting.set("greeting_voice", "Polly.Carla")

    list = Setting.all_with_defaults
    voice = list.find { |s| s.key == "greeting_voice" }
    sensitivity = list.find { |s| s.key == "spam_sensitivity" }

    assert_equal "Polly.Carla", voice.value
    assert_equal "0.5", sensitivity.value
    assert_equal Setting::DEFAULTS.size, list.size
  end

  # === Validators (NEW M13) ===

  test "set accepts valid spam_sensitivity in 0..1" do
    assert_nothing_raised { Setting.set("spam_sensitivity", "0.0") }
    assert_nothing_raised { Setting.set("spam_sensitivity", "0.7") }
    assert_nothing_raised { Setting.set("spam_sensitivity", "1.0") }
  end

  test "set rejects spam_sensitivity outside 0..1 or non-numeric" do
    assert_raises(Setting::InvalidValue) { Setting.set("spam_sensitivity", "1.5") }
    assert_raises(Setting::InvalidValue) { Setting.set("spam_sensitivity", "-0.1") }
    assert_raises(Setting::InvalidValue) { Setting.set("spam_sensitivity", "abc") }
  end

  test "set rejects max_recording_seconds outside 5..600" do
    assert_raises(Setting::InvalidValue) { Setting.set("max_recording_seconds", "0") }
    assert_raises(Setting::InvalidValue) { Setting.set("max_recording_seconds", "9999") }
    assert_raises(Setting::InvalidValue) { Setting.set("max_recording_seconds", "abc") }
    assert_nothing_raised { Setting.set("max_recording_seconds", "120") }
  end

  test "set rejects malformed greeting_language" do
    assert_raises(Setting::InvalidValue) { Setting.set("greeting_language", "english") }
    assert_raises(Setting::InvalidValue) { Setting.set("greeting_language", "EN-US") }
    assert_nothing_raised { Setting.set("greeting_language", "it-IT") }
    assert_nothing_raised { Setting.set("greeting_language", "en-US") }
  end

  test "set rejects greeting_voice with XML-attribute-injection characters" do
    assert_raises(Setting::InvalidValue) do
      Setting.set("greeting_voice", 'alice"><Hangup/><Say voice="alice')
    end
    assert_raises(Setting::InvalidValue) { Setting.set("greeting_voice", "<script>") }
    assert_nothing_raised { Setting.set("greeting_voice", "Polly.Bianca-Neural") }
  end

  test "set rejects greeting_text longer than 500 chars" do
    assert_raises(Setting::InvalidValue) { Setting.set("greeting_text", "x" * 501) }
    assert_nothing_raised { Setting.set("greeting_text", "x" * 500) }
    assert_raises(Setting::InvalidValue) { Setting.set("greeting_text", "") }
  end

  test "screening_speech_timeout accepts auto or integer 1..60" do
    assert_nothing_raised { Setting.set("screening_speech_timeout", "auto") }
    assert_nothing_raised { Setting.set("screening_speech_timeout", "5") }
    assert_raises(Setting::InvalidValue) { Setting.set("screening_speech_timeout", "0") }
    assert_raises(Setting::InvalidValue) { Setting.set("screening_speech_timeout", "abc") }
  end

  test "auto_delete_days accepts 1..3650" do
    assert_nothing_raised { Setting.set("auto_delete_days", "30") }
    assert_nothing_raised { Setting.set("auto_delete_days", "365") }
    assert_raises(Setting::InvalidValue) { Setting.set("auto_delete_days", "0") }
    assert_raises(Setting::InvalidValue) { Setting.set("auto_delete_days", "10000") }
  end

  test "set ignores unknown keys (no validator, persists raw)" do
    assert_nothing_raised { Setting.set("custom_unknown_key", "anything goes") }
    assert_equal "anything goes", Setting.find_by(key: "custom_unknown_key").value
  end

  test "transcription_engine accepts the four supported engines" do
    Setting::ALLOWED_TRANSCRIPTION_ENGINES.each do |engine|
      assert_nothing_raised { Setting.set("transcription_engine", engine) }
      assert_equal engine, Setting.get("transcription_engine")
    end
  end

  test "transcription_engine rejects unknown engines (case-sensitive)" do
    assert_raises(Setting::InvalidValue) { Setting.set("transcription_engine", "OpenAI") }
    assert_raises(Setting::InvalidValue) { Setting.set("transcription_engine", "google") } # lowercase
    assert_raises(Setting::InvalidValue) { Setting.set("transcription_engine", "") }
  end

  test "transcription_engine default is Google" do
    Setting.where(key: "transcription_engine").destroy_all
    assert_equal "Google", Setting.get("transcription_engine")
  end
end
