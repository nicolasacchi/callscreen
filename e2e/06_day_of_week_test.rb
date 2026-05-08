# frozen_string_literal: true
require_relative "e2e_helper"

class DayOfWeekTest < E2ETest
  def setup
    super
    assign_phrases_to_contact!(
      phone: E2E_CALLER_DOW,
      phrase_slugs: %w[e2e_weekend e2e_anyday]
    )
  end

  def test_saturday_call_picks_weekend_phrase
    # 2026-05-09 is a Saturday.
    result = fire_call(from: E2E_CALLER_DOW, now: "2026-05-09T14:00:00+02:00")
    assert_nil result.error
    call = read_call(result.call_control_id)
    assert_equal "e2e_weekend", call["selected_phrase_slug"]
  end

  def test_friday_call_falls_through_to_anyday
    # 2026-05-08 is a Friday.
    result = fire_call(from: E2E_CALLER_DOW, now: "2026-05-08T14:00:00+02:00")
    assert_nil result.error
    call = read_call(result.call_control_id)
    assert_equal "e2e_anyday", call["selected_phrase_slug"]
  end
end
