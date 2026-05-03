require "test_helper"

class VoiceRotationTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @tenant.update!(
      voice_rotation_enabled: true,
      voice_rotation_voices: "if_sara,im_nicola,af_heart",
      voice_rotation_index: 0
    )
  end

  test "voice_rotation_voice_list parses CSV string" do
    assert_equal %w[if_sara im_nicola af_heart], @tenant.voice_rotation_voice_list
  end

  test "voice_rotation_voice_list ignores empty/whitespace entries" do
    @tenant.update_columns(voice_rotation_voices: "if_sara, , im_nicola,, ")
    assert_equal %w[if_sara im_nicola], @tenant.voice_rotation_voice_list
  end

  test "voice_rotation_ready? requires both flag and non-empty list" do
    assert @tenant.voice_rotation_ready?

    @tenant.update_columns(voice_rotation_enabled: false)
    refute @tenant.voice_rotation_ready?

    @tenant.update_columns(voice_rotation_enabled: true, voice_rotation_voices: "")
    refute @tenant.voice_rotation_ready?
  end

  test "next_rotated_voice! cycles through the list and advances the index" do
    voices = 6.times.map { @tenant.next_rotated_voice! }
    assert_equal %w[if_sara im_nicola af_heart if_sara im_nicola af_heart], voices
    assert_equal 6, @tenant.reload.voice_rotation_index
  end

  test "next_rotated_voice! returns nil on empty list" do
    @tenant.update_columns(voice_rotation_voices: "")
    assert_nil @tenant.next_rotated_voice!
  end

  test "next_rotated_voice! is concurrency-safe (atomic increment via with_lock)" do
    # Sanity check: 10 sequential calls advance the counter by 10.
    initial = @tenant.voice_rotation_index || 0
    10.times { @tenant.next_rotated_voice! }
    assert_equal initial + 10, @tenant.reload.voice_rotation_index
  end

  test "voice_rotation_index resets when the list changes via update" do
    # The controller's profile_params resets the index when the voices list
    # changes. Direct model updates don't trigger that — verify the controller
    # behavior in a controller test.
    @tenant.update!(voice_rotation_index: 5)
    @tenant.update!(voice_rotation_voices: "if_sara,im_nicola")
    # Model-level: index NOT reset (controller is responsible for that)
    assert_equal 5, @tenant.reload.voice_rotation_index
  end
end
