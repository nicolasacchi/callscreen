class WhisperClient
  ALLOWED_LANGUAGES = %w[it en].freeze

  # Raised when transcription could not be obtained because of a transport
  # failure (sidecar down, 5xx, timeout, unparseable body) — as opposed to a
  # successful call that legitimately returned an empty transcript. Callers
  # (ScreeningJob) retry on this so a Whisper outage doesn't get committed as
  # "the caller said nothing" (status: :unknown).
  class TransportError < StandardError; end

  def initialize(audio_file_path, language: "it")
    @audio_file_path = audio_file_path
    @language = ALLOWED_LANGUAGES.include?(language.to_s) ? language.to_s : "it"
  end

  # Returns the transcript String (possibly "" when the caller genuinely said
  # nothing). Raises TransportError on any transport/parse failure.
  def transcribe
    response = HTTParty.post(
      "#{base_url}/v1/audio/transcriptions",
      multipart: true,
      body: {
        file: File.open(@audio_file_path, "rb"),
        model: "Systran/faster-whisper-medium",
        language: @language,
        response_format: "json"
      },
      headers: { "X-Request-ID" => Current.request_id.to_s },
      timeout: 120
    )

    unless response.success?
      # Log only the status + a truncated body — the body can echo back
      # transcription content (caller PII) into STDOUT logs.
      Rails.logger.error("Whisper transcription failed: HTTP #{response.code} #{response.body.to_s.first(200)}")
      raise TransportError, "Whisper HTTP #{response.code}"
    end

    JSON.parse(response.body)["text"].to_s
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, JSON::ParserError, HTTParty::Error => e
    Rails.logger.error("WhisperClient transport error: #{e.class}: #{e.message}")
    raise TransportError, "#{e.class}: #{e.message}"
  end

  private

  def base_url
    ENV.fetch("WHISPER_API_URL", "http://faster-whisper:8000")
  end
end
