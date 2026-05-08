#!/usr/bin/env ruby
# frozen_string_literal: true
#
# CLI wrapper around lib/synthetic_call.rb. Posts the canonical Telnyx
# event sequence against /telnyx/voice on a target server, optionally
# polls the production DB for the resulting Call state via docker exec.
#
# Usage:
#   bin/synthetic_call --from +393331112222 --to +390123456789
#   bin/synthetic_call --target https://phone.example.com --token "$SYNTHETIC_WEBHOOK_TOKEN"
#   bin/synthetic_call --recording-url https://api.telnyx.com/.../rec.wav --watch
#   bin/synthetic_call --skip-recording                # fastest; greeting + hangup only
#   bin/synthetic_call --now 2026-05-09T08:00:00+02:00 # injects time into the resolver

require "optparse"
require_relative "../lib/synthetic_call"

TARGET_DEFAULT      = "https://phone.example.com"
TENANT_TO_DEFAULT   = "+390999000355"
TENANT_FROM_DEFAULT = "+393331112222"

options = {
  target:           ENV["SC_TARGET"] || TARGET_DEFAULT,
  token:            ENV["SYNTHETIC_WEBHOOK_TOKEN"],
  from:             TENANT_FROM_DEFAULT,
  to:               TENANT_TO_DEFAULT,
  recording_url:    nil,
  skip_recording:   false,
  skip_hangup:      false,
  watch:            false,
  pause:            0.5,
  recording_pause:  20,
  now:              nil,
  verbose:          false
}

OptionParser.new do |o|
  o.banner = "Usage: scripts/synthetic_call.rb [options]"
  o.on("--target URL",          "Webhook base URL (default: #{TARGET_DEFAULT})")     { |v| options[:target] = v }
  o.on("--token TOKEN",         "Synthetic webhook token (env: SYNTHETIC_WEBHOOK_TOKEN)") { |v| options[:token] = v }
  o.on("--from E164",           "Caller number (default: #{TENANT_FROM_DEFAULT})")   { |v| options[:from] = v }
  o.on("--to E164",             "Tenant number (default: #{TENANT_TO_DEFAULT})")     { |v| options[:to] = v }
  o.on("--recording-url URL",   "URL to set as recording_url on call.recording.saved") { |v| options[:recording_url] = v }
  o.on("--now ISO8601",         "Inject time-of-call (X-E2E-Now header) e.g. 2026-05-09T08:00:00+02:00") { |v| options[:now] = v }
  o.on("--skip-recording",      "Skip call.recording.saved → no ScreeningJob")        { options[:skip_recording] = true }
  o.on("--skip-hangup",         "Skip call.hangup")                                   { options[:skip_hangup] = true }
  o.on("--watch",               "Poll production DB after firing; print final Call state") { options[:watch] = true }
  o.on("--pause SEC",           Float, "Sleep between events (default: 0.5)")        { |v| options[:pause] = v }
  o.on("--recording-pause SEC", Float, "Sleep before --watch read (default: 20s)")   { |v| options[:recording_pause] = v }
  o.on("-v", "--verbose")                                                             { options[:verbose] = true }
end.parse!

# Resolve token: --token > $SYNTHETIC_WEBHOOK_TOKEN > docker exec lookup.
options[:token] = ENV["SYNTHETIC_WEBHOOK_TOKEN"] if options[:token].nil? || options[:token].empty?
if options[:token].nil? || options[:token].empty?
  warn "Trying to read SYNTHETIC_WEBHOOK_TOKEN from the running container…"
  resolved = `docker exec callscreen bash -c 'echo $SYNTHETIC_WEBHOOK_TOKEN' 2>/dev/null`.strip
  options[:token] = resolved unless resolved.empty?
end
if options[:token].nil? || options[:token].empty?
  abort <<~MSG
    ERROR: synthetic webhook token not set.
      Set SYNTHETIC_WEBHOOK_TOKEN in the container's environment (a long
      random string, distinct from WEBHOOK_TOKEN), redeploy, then re-run
      this script.

      Generate one:  openssl rand -hex 32
  MSG
end

scenario = SyntheticCall::DEFAULT_SCENARIO.dup
scenario.delete(:recording_saved) if options[:skip_recording]
scenario.delete(:hangup)          if options[:skip_hangup]

puts "Synthetic call against #{options[:target]}"
puts "  from → to: #{options[:from]} → #{options[:to]}"
puts "  scenario: #{scenario.inspect}"
puts "  now (X-E2E-Now): #{options[:now] || '(real time)'}"
puts "  events:"

result = SyntheticCall.fire(
  target:        options[:target],
  token:         options[:token],
  from:          options[:from],
  to:            options[:to],
  recording_url: options[:recording_url],
  scenario:      scenario,
  now:           options[:now],
  pause:         options[:pause],
  verbose:       true
)

puts "  call_control_id: #{result.call_control_id}"
abort "ERROR: #{result.error}" if result.error

if options[:watch]
  puts ""
  puts "Waiting #{options[:recording_pause]}s for ScreeningJob/NotifyJob to finish…"
  sleep options[:recording_pause]

  ruby_snippet = <<~RUBY
    c = Call.find_by(call_sid: ENV["SC_SID"])
    if c.nil?
      puts "Call NOT found"
    else
      puts "  call_id        : \#{c.id}"
      puts "  status         : \#{c.status}"
      puts "  flow_state     : \#{c.flow_state}"
      puts "  from_number    : \#{c.from_number}"
      puts "  to_number      : \#{c.to_number}"
      puts "  contact        : \#{c.contact&.display_name.inspect}"
      puts "  recording_url  : \#{c.recording_url.inspect}"
      puts "  duration       : \#{c.duration_seconds}s"
      puts "  selected_phrase: \#{c.selected_phrase_slug.inspect}"
      puts "  transcript     : \#{c.screening_transcript.to_s[0, 120].inspect}"
      puts "  ai_class       : \#{c.ai_classification.inspect}"
      puts "  notified_at    : \#{c.notified_at.inspect}"
    end
  RUBY

  puts "Reading Call from production DB:"
  cmd = [ "docker", "exec",
          "-e", "SC_SID=#{result.call_control_id}",
          "callscreen", "bin/rails", "runner", ruby_snippet ]
  system(*cmd)
end

puts ""
puts "Inspect the call:"
puts "  https://phone.example.com/admin/calls"
puts "  (search for #{result.call_control_id.split(':').last[0, 16]})"
