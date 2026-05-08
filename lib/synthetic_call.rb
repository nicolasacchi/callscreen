# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

# Posts the canonical Telnyx event sequence to /telnyx/voice on a target
# server, authenticated via SYNTHETIC_WEBHOOK_TOKEN. Drives the full
# server-side flow end-to-end without a real call leg. Used by:
#
#   - bin/synthetic_call (CLI wrapper, scripts/synthetic_call.rb)
#   - test/e2e/*_test.rb (live e2e suite)
#
# `now:` (Time or ISO8601 String) is sent on every event as the
# `X-E2E-Now` header so the controller can inject it into
# PhrasePoolResolver for time-of-day / day-of-week tests.
class SyntheticCall
  Result = Struct.new(:call_control_id, :http_codes, :error, keyword_init: true)

  DEFAULT_SCENARIO = %i[initiated answered playback_ended recording_saved hangup].freeze

  def self.fire(target:, token:, from:, to:,
                scenario: DEFAULT_SCENARIO,
                now: nil, recording_url: nil, pause: 0.5, verbose: false)
    new(target: target, token: token, from: from, to: to,
        now: now, recording_url: recording_url,
        pause: pause, verbose: verbose).fire(scenario)
  end

  def initialize(target:, token:, from:, to:, now: nil, recording_url: nil,
                 pause: 0.5, verbose: false)
    @target        = target
    @token         = token
    @from          = from
    @to            = to
    @now_header    = now.is_a?(Time) ? now.iso8601 : now.to_s
    @recording_url = recording_url
    @pause         = pause
    @verbose       = verbose

    @suffix    = SecureRandom.hex(8)
    @ccid      = "v3:synthetic-#{@suffix}"
    @leg       = SecureRandom.uuid
    @session   = SecureRandom.uuid
    @start_iso = Time.now.utc.iso8601(6)
  end

  def fire(scenario)
    codes = {}
    scenario.each do |evt|
      method = "post_#{evt}"
      raise ArgumentError, "unknown scenario step #{evt}" unless respond_to?(method, true)
      codes[evt] = send(method)
      sleep @pause if @pause.positive?
    end
    Result.new(call_control_id: @ccid, http_codes: codes, error: nil)
  rescue StandardError => e
    Result.new(call_control_id: @ccid, http_codes: {}, error: "#{e.class}: #{e.message}")
  end

  attr_reader :ccid

  private

  def post_initiated
    post_event("call.initiated", base_payload.merge(
      "caller_id_name"     => "Synthetic Test",
      "direction"          => "incoming",
      "state"              => "parked",
      "offered_codecs"     => "G729,PCMA",
      "connection_codecs"  => "G722,PCMA,PCMU",
      "from_sip_uri"       => "<sip:#{@from}@example.test>",
      "to_sip_uri"         => "<sip:#{@to}@example.test>",
      "sip_headers"        => []
    ))
  end

  def post_answered
    post_event("call.answered", base_payload.merge(
      "codec"         => "PCMA",
      "sampling_rate" => 8000,
      "sip_headers"   => []
    ))
  end

  def post_playback_ended
    post_event("call.playback.ended", base_payload.merge(
      "media_url"   => "#{@target}/greetings/informal_tu/im_nicola/natural.wav",
      "media_name"  => nil,
      "playback_id" => SecureRandom.alphanumeric(10),
      "overlay"     => false,
      "status"      => "completed"
    ))
  end

  def post_recording_saved
    rec_url = @recording_url ||
              "https://api.telnyx.com/v2/recordings/synthetic-#{@suffix}.wav"
    post_event("call.recording.saved", base_payload.merge(
      "recording_id"     => SecureRandom.uuid,
      "recording_urls"   => { "wav" => rec_url },
      "recording_url"    => rec_url,
      "duration_seconds" => 4,
      "channels"         => "single",
      "format"           => "wav"
    ))
  end

  def post_hangup
    post_event("call.hangup", base_payload.merge(
      "hangup_cause"     => "normal_clearing",
      "hangup_source"    => "caller",
      "sip_hangup_cause" => "200",
      "end_time"         => Time.now.utc.iso8601(6),
      "telnyx_error"     => nil
    ))
  end

  def base_payload
    {
      "call_control_id"    => @ccid,
      "call_leg_id"        => @leg,
      "call_session_id"    => @session,
      "calling_party_type" => "pstn",
      "client_state"       => nil,
      "connection_id"      => "synthetic-connection",
      "from"               => @from,
      "to"                 => @to,
      "start_time"         => @start_iso
    }
  end

  def post_event(event_type, payload)
    uri = URI("#{@target}/telnyx/voice?synthetic_token=#{URI.encode_www_form_component(@token)}")
    body = {
      "data" => {
        "event_type"  => event_type,
        "id"          => SecureRandom.uuid,
        "occurred_at" => Time.now.utc.iso8601(6),
        "payload"     => payload,
        "record_type" => "event"
      },
      "meta" => { "attempt" => 1 }
    }

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]    = "application/json"
    req["User-Agent"]      = "callscreen-synthetic/1"
    req["X-Synthetic-Call"] = "1"
    req["X-E2E-Now"]       = @now_header unless @now_header.empty?
    req.body = JSON.generate(body)

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.read_timeout = 30
      res = http.request(req)
      warn "  ✓ #{event_type.ljust(24)} → HTTP #{res.code}" if @verbose || res.code.to_i >= 300
      res.code
    end
  end
end
