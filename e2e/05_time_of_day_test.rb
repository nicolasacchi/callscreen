# frozen_string_literal: true

require_relative "e2e_helper"

class TimeOfDayTest < E2ETest
  def setup
    super
    assign_phrases_to_contact!(
      phone: E2E_CALLER_TOD,
      phrase_slugs: %w[e2e_morning e2e_anytime]
    )
  end

  def test_morning_call_picks_morning_phrase
    result = fire_call(from: E2E_CALLER_TOD, now: "2026-05-06T08:00:00+02:00")
    assert_nil result.error
    call = read_call(result.call_control_id)
    assert_equal "e2e_morning", call["selected_phrase_slug"]
  end

  def test_night_call_falls_through_to_anytime
    result = fire_call(from: E2E_CALLER_TOD, now: "2026-05-06T23:00:00+02:00")
    assert_nil result.error
    call = read_call(result.call_control_id)
    assert_equal "e2e_anytime", call["selected_phrase_slug"]
  end
end
