# frozen_string_literal: true

require_relative "e2e_helper"

class PerContactPoolTest < E2ETest
  def test_contact_with_assigned_phrase_plays_that_phrase
    assign_phrases_to_contact!(phone: E2E_CALLER_POOL,
                                phrase_slugs: [ "e2e_pool_specific" ])
    result = fire_call(from: E2E_CALLER_POOL)
    assert_nil result.error
    call = read_call(result.call_control_id)
    assert_equal "e2e_pool_specific", call["selected_phrase_slug"]
  end
end
