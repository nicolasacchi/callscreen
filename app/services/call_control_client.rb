require "net/http"
require "json"
require "uri"

# Thin wrapper around Telnyx Voice API outbound commands. Each method
# corresponds to one POST /v2/calls/{call_control_id}/actions/{verb}.
# Errors are logged and swallowed so a failed command never aborts the
# webhook acknowledgement (Telnyx retries the inbound webhook if we 5xx,
# which would replay the whole flow). The webhook handler returns 200
# regardless; the command's success can be observed via the next event
# Telnyx fires (call.answered, call.gather.ended, …).
class CallControlClient
  API_BASE = "https://api.telnyx.com/v2"
  DEFAULT_TIMEOUT = 5

  def initialize(api_key: ENV["TELNYX_API_KEY"], app_domain: ENV.fetch("APP_DOMAIN", "https://phone.example.com"))
    @api_key    = api_key.to_s
    @app_domain = app_domain.to_s.chomp("/")
  end

  # === High-level command helpers ===

  def answer(call_control_id, **opts)
    post(call_control_id, :answer, opts)
  end

  def reject(call_control_id, cause: "USER_BUSY")
    post(call_control_id, :reject, cause: cause)
  end

  def hangup(call_control_id)
    post(call_control_id, :hangup, {})
  end

  # Plays a remote audio file. URL must be HTTPS-reachable from Telnyx.
  def playback_start(call_control_id, audio_url:, loop: 1)
    post(call_control_id, :playback_start, audio_url: audio_url, loop: loop)
  end

  def speak(call_control_id, payload:, voice: "alice", language: "it-IT", payload_type: "text")
    post(call_control_id, :speak, payload: payload, voice: voice, language: language, payload_type: payload_type)
  end

  # Plays an audio file then captures DTMF digits.
  #
  # IMPORTANT: Telnyx Voice API's gather_using_audio is DTMF-ONLY. It does
  # NOT support speech transcription, despite TeXML's <Gather> verb having
  # transcriptionEngine. For speech capture, use record_start (then
  # transcribe externally) or transcription_start (streaming). The
  # `language` arg here only validates valid_digits, not transcription.
  #
  # Telnyx requires maximum_digits/minimum_digits to be in [1, 128] if
  # present at all — sending 0 returns a 422. We omit them unless the caller
  # explicitly opts in (e.g., for an "enter your extension" gather).
  def gather_using_audio(call_control_id, audio_url:, language: "it-IT",
                         valid_digits: nil,
                         maximum_digits: nil,
                         minimum_digits: nil,
                         total_timeout_secs: 30)
    body = {
      audio_url: audio_url,
      language: language,
      total_timeout_secs: total_timeout_secs
    }
    body[:valid_digits]   = valid_digits   if valid_digits
    body[:maximum_digits] = maximum_digits if maximum_digits&.positive?
    body[:minimum_digits] = minimum_digits if minimum_digits&.positive?
    post(call_control_id, :gather_using_audio, body)
  end

  # DTMF-only counterpart to gather_using_audio. Speaks a TTS prompt, then
  # captures keypad digits. NOT used for speech recognition (see
  # gather_using_audio's note for details).
  def gather_using_speak(call_control_id, payload:, voice: "alice", language: "it-IT",
                         maximum_digits: nil,
                         minimum_digits: nil,
                         total_timeout_secs: 30)
    body = {
      payload: payload,
      voice: voice,
      language: language,
      payload_type: "text",
      total_timeout_secs: total_timeout_secs
    }
    body[:maximum_digits] = maximum_digits if maximum_digits&.positive?
    body[:minimum_digits] = minimum_digits if minimum_digits&.positive?
    post(call_control_id, :gather_using_speak, body)
  end

  # Starts recording the active call leg. Telnyx fires call.recording.saved
  # when the file is ready.
  #
  # timeout_secs (optional, integer): "When no speech is detected for the
  # given amount of seconds, the recording will be stopped." Setting it
  # combines a silence-end-of-speech detector with the max_length hard cap.
  # Omit to record up to max_length regardless of silence (voicemail-style).
  def record_start(call_control_id, format: "wav", channels: "single", max_length: 120,
                   timeout_secs: nil, play_beep: true, trim: "trim-silence")
    body = {
      format: format,
      channels: channels,
      max_length: max_length,
      play_beep: play_beep,
      trim: trim
    }
    body[:timeout_secs] = timeout_secs if timeout_secs&.positive?
    post(call_control_id, :record_start, body)
  end

  # Forwards the call to a PSTN number. Timeout MUST stay below the carrier
  # no-answer threshold (typical Italian: 20-25s) to avoid forwarding loops.
  def transfer(call_control_id, to:, from: nil, timeout_secs: 15)
    body = { to: to, timeout_secs: timeout_secs }
    body[:from] = from if from
    post(call_control_id, :transfer, body)
  end

  # === Low-level ===

  def post(call_control_id, action, body)
    return failure("missing api key") if @api_key.empty?
    return failure("missing call_control_id") if call_control_id.to_s.empty?

    uri = URI("#{API_BASE}/calls/#{call_control_id}/actions/#{action}")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@api_key}"
    req["Content-Type"]  = "application/json"
    req["X-Request-ID"]  = Current.request_id.to_s
    req.body = JSON.dump(body)

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          read_timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_TIMEOUT) do |http|
      http.request(req)
    end

    if res.code.to_i.between?(200, 299)
      { ok: true, status: res.code.to_i }
    else
      Rails.logger.warn("CallControlClient #{action} → #{res.code}: #{truncate(res.body)}")
      { ok: false, status: res.code.to_i, body: res.body }
    end
  rescue StandardError => e
    Rails.logger.error("CallControlClient #{action} failed: #{e.class}: #{e.message}")
    failure(e.message)
  end

  private

  def failure(reason)
    { ok: false, error: reason }
  end

  def truncate(s)
    s.to_s.first(500)
  end
end
