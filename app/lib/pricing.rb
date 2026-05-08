module Pricing
  TELNYX_VOICE_PER_MIN_USD =
    ENV.fetch("CALLSCREEN_TELNYX_USD_PER_MIN", "0.0070").to_f
  MOONSHOT_INPUT_PER_1M_USD =
    ENV.fetch("CALLSCREEN_MOONSHOT_INPUT_USD_PER_1M", "0.20").to_f
  MOONSHOT_OUTPUT_PER_1M_USD =
    ENV.fetch("CALLSCREEN_MOONSHOT_OUTPUT_USD_PER_1M", "2.00").to_f

  CHARS_PER_TOKEN_ESTIMATE = 4
  # Pinned to the measured size of SpamClassifier#system_prompt +
  # user_message_template. Refresh whenever those strings change.
  FIXED_PROMPT_TOKEN_ESTIMATE = 340
  ESTIMATED_OUTPUT_TOKENS = 80

  module_function

  def telnyx_voice_usd(seconds)
    return 0.0 if seconds.to_i.zero?
    (seconds.to_f / 60.0) * TELNYX_VOICE_PER_MIN_USD
  end

  def moonshot_usd(tokens_in, tokens_out)
    return 0.0 if tokens_in.nil? && tokens_out.nil?
    (tokens_in.to_f  / 1_000_000) * MOONSHOT_INPUT_PER_1M_USD +
    (tokens_out.to_f / 1_000_000) * MOONSHOT_OUTPUT_PER_1M_USD
  end

  def estimate_moonshot_from_chars(transcript_chars)
    return 0.0 if transcript_chars.to_i.zero?
    tokens_in = FIXED_PROMPT_TOKEN_ESTIMATE +
                (transcript_chars.to_i / CHARS_PER_TOKEN_ESTIMATE)
    moonshot_usd(tokens_in, ESTIMATED_OUTPUT_TOKENS)
  end
end
