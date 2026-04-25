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
end
