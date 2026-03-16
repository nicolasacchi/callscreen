class SpamClassifier
  ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"

  def initialize(transcript, from_number:)
    @transcript = transcript
    @from_number = from_number
  end

  def classify
    response = HTTParty.post(ENDPOINT,
      headers: {
        "Authorization" => "Bearer #{ENV['OPENROUTER_API_KEY']}",
        "Content-Type" => "application/json",
        "X-Title" => "AI Call Screener"
      },
      body: {
        model: ENV.fetch("OPENROUTER_MODEL", "anthropic/claude-sonnet-4-20250514"),
        messages: messages,
        max_tokens: 200,
        temperature: 0
      }.to_json,
      timeout: 15
    )

    parse_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error("SpamClassifier timeout: #{e.message}")
    uncertain("LLM timeout")
  rescue => e
    Rails.logger.error("SpamClassifier error: #{e.class}: #{e.message}")
    uncertain("Classification error: #{e.message}")
  end

  private

  def messages
    [
      { role: "system", content: system_prompt },
      { role: "user", content: "Caller phone number: #{@from_number}\nTranscript: \"#{@transcript}\"" }
    ]
  end

  def system_prompt
    sensitivity = Setting.get("spam_sensitivity")
    <<~PROMPT
      You are a phone call spam classifier for an Italian phone number.
      You receive the transcript of what a caller said when asked to identify themselves and state their reason for calling.

      Classify the call as one of:
      - "spam": telemarketing, robocall scripts, scam attempts, unsolicited sales, automated messages, surveys, "you've won" scams, energy/phone/internet contract offers, fake financial services, charity solicitations
      - "legit": personal calls, deliveries (corriere, postino, Amazon, GLS, BRT, SDA), medical/doctor offices, appointments, known businesses calling back, government/official (INPS, Agenzia delle Entrate, ASL), someone clearly looking for the phone owner by name, utility companies about existing service issues
      - "uncertain": ambiguous, unclear transcription, could go either way, very short or garbled

      Respond ONLY with valid JSON, no markdown, no backticks:
      {"classification": "spam"|"legit"|"uncertain", "confidence": 0.85, "reason": "brief explanation in english"}

      Err on the side of "legit" or "uncertain" — better to take an unnecessary voicemail than hang up on a real caller.

      Current spam sensitivity: #{sensitivity} (0.0 = permissive, 1.0 = aggressive)
      The transcript may be Italian or English and may contain transcription errors.
    PROMPT
  end

  def parse_response(response)
    body = JSON.parse(response.body)
    content = body.dig("choices", 0, "message", "content")
    result = JSON.parse(content)
    result.transform_keys(&:to_s)
  rescue JSON::ParserError => e
    Rails.logger.error("SpamClassifier JSON parse error: #{e.message}, content: #{content}")
    uncertain("Failed to parse LLM response")
  end

  def uncertain(reason)
    { "classification" => "uncertain", "confidence" => 0.0, "reason" => reason }
  end
end
