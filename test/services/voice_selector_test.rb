require "test_helper"

class VoiceSelectorTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @tenant.update!(greeting_voice: "im_nicola", voice_rotation_enabled: false, voice_clone_active: false)
    @call = @tenant.calls.create!(call_sid: "vs-1", from_number: "+390000000001", status: :screening)
  end

  test "falls back to the tenant default voice and caches it" do
    assert_equal "im_nicola", VoiceSelector.for_call!(@call)
    assert_equal "im_nicola", @call.reload.selected_voice
  end

  test "advances the rotation cursor at most once per call (cached re-pick)" do
    @tenant.update!(voice_rotation_enabled: true, voice_rotation_voices: "if_sara,im_nicola")
    first = VoiceSelector.for_call!(@call)
    idx = @tenant.reload.voice_rotation_index
    second = VoiceSelector.for_call!(@call)
    assert_equal first, second
    assert_equal idx, @tenant.reload.voice_rotation_index, "cursor must not advance on the cached re-pick"
  end
end
