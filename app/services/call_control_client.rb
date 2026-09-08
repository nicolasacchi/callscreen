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

  def initialize(api_key: ENV["TELNYX_API_KEY"], app_domain: ENV.fetch("APP_DOMAIN", "https://example.com"))
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

  # NOTE: gather_using_audio / gather_using_speak (DTMF capture) were removed —
  # the Voice API screening flow captures speech via record_start + Whisper, and
  # nothing called them. See git history if an "enter your extension" DTMF
  # feature is ever needed.

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
    # Surface transport failures (timeouts/connection errors) — a dropped
    # outbound command can strand a live call leg; the stuck-call sweep cleans
    # it up, but the operator should still see the underlying failures.
    Sentry.capture_exception(e) if defined?(Sentry)
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
