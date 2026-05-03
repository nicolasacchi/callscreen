class WhisperClient
  ALLOWED_LANGUAGES = %w[it en].freeze

  def initialize(audio_file_path, language: "it")
    @audio_file_path = audio_file_path
    @language = ALLOWED_LANGUAGES.include?(language.to_s) ? language.to_s : "it"
  end

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

    if response.success?
      JSON.parse(response.body)["text"]
    else
      Rails.logger.error("Whisper transcription failed: #{response.code} #{response.body}")
      nil
    end
  rescue => e
    Rails.logger.error("WhisperClient error: #{e.class}: #{e.message}")
    nil
  end

  private

  def base_url
    ENV.fetch("WHISPER_API_URL", "http://faster-whisper:8000")
  end
end
