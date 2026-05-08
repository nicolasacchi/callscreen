# frozen_string_literal: true
require_relative "e2e_helper"

class VoiceRotationTest < E2ETest
  def test_two_calls_advance_cursor_by_two
    override_tenant!(
      voice_rotation_enabled: true,
      voice_rotation_voices: "if_sara,im_nicola",
      voice_rotation_index: 0
    )

    # Full event sequence (greeting + goodbye both fire). The
    # post-2026-05-07 fix advances the cursor exactly once per call,
    # so two calls produce voice_rotation_index = 2 even though
    # goodbye also runs. Pre-fix this would have been 4.
    fire_call(from: E2E_CALLER_VOICEROT)
    fire_call(from: E2E_CALLER_VOICEROT)

    tenant = read_tenant("e2e")
    assert_equal 2, tenant["voice_rotation_index"],
                 "expected cursor to advance by 2 (one per call) after two calls"
  end
end
