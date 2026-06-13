# frozen_string_literal: true

require_relative "e2e_helper"

class RateLimitTest < E2ETest
  def test_sixth_call_in_window_is_rate_limited
    # max_calls_per_caller_per_day is 5 in the deterministic config.
    # Fire 6 back-to-back; only 5 of them go through the screening flow,
    # the 6th hits the rate-limit branch and is rejected with status: spam.
    # (auto_blacklist_threshold is 0 — disabled — so cumulative spam
    # classifications can't auto-blacklist mid-test.)
    results = 6.times.map do |_i|
      # No --recording so ScreeningJob doesn't fire downloading-failure
      # spam (which would also trip blacklist if enabled).
      fire_call(from: E2E_CALLER_RATELIMIT,
                scenario: %i[initiated answered playback_ended hangup])
    end

    last_call = read_call(results.last.call_control_id)
    assert_equal "spam", last_call["status"]
    reason = last_call.dig("ai_classification", "reason").to_s
    assert_match(/Rate.?limited/i, reason,
                 "expected rate-limit reason, got: #{last_call["ai_classification"].inspect}")
  end
end
