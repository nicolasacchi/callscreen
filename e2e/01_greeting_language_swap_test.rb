# frozen_string_literal: true
require_relative "e2e_helper"

class GreetingLanguageSwapTest < E2ETest
  def test_italian_caller_gets_italian_phrase
    result = fire_call(from: E2E_CALLER_LANGSWAP_IT)
    assert_nil result.error, "fire_call: #{result.error}"
    call = read_call(result.call_control_id)
    refute_nil call["selected_phrase_slug"], "selected_phrase_slug should be set"
    phrase = read_phrase(call["selected_phrase_slug"])
    refute_nil phrase, "phrase #{call['selected_phrase_slug']} not found"
    assert phrase["text_it"].to_s.length.positive?,
           "+39 caller should get phrase with text_it; got #{phrase.inspect}"
  end

  def test_english_caller_gets_english_phrase
    result = fire_call(from: E2E_CALLER_LANGSWAP_EN)
    assert_nil result.error
    call = read_call(result.call_control_id)
    refute_nil call["selected_phrase_slug"]
    phrase = read_phrase(call["selected_phrase_slug"])
    assert phrase["text_en"].to_s.length.positive?,
           "non-+39 caller should get phrase with text_en; got #{phrase.inspect}"
  end
end
