# frozen_string_literal: true

# Live e2e test base class. Loaded once per test file via
# `require_relative "e2e_helper"`. The test process is HTTP-only Ruby —
# no Rails env booted in-process. State mutation goes via docker exec
# to the production Rails runner; reads go via the JSON inspector
# endpoint.
require "minitest/autorun"
require "json"
require "net/http"
require "uri"
require "shellwords"
require "securerandom"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "synthetic_call"

class E2ETest < Minitest::Test
  TARGET = ENV.fetch("E2E_AGAINST")
  TOKEN  = ENV.fetch("SYNTHETIC_WEBHOOK_TOKEN")

  E2E_TENANT_SLUG    = "e2e"
  E2E_TENANT_NUMBER  = "+390999000000"

  E2E_CALLER_LANGSWAP_IT = "+390999000101"
  E2E_CALLER_LANGSWAP_EN = "+447700900099"
  E2E_CALLER_POOL        = "+390999000102"
  E2E_CALLER_VOICEROT    = "+390999000103"
  E2E_CALLER_NTFY        = "+390999000104"
  E2E_CALLER_TOD         = "+390999000105"
  E2E_CALLER_DOW         = "+390999000106"
  E2E_CALLER_RATELIMIT   = "+390999000107"

  ALL_E2E_CALLERS = [
    E2E_CALLER_LANGSWAP_IT, E2E_CALLER_LANGSWAP_EN,
    E2E_CALLER_POOL, E2E_CALLER_VOICEROT, E2E_CALLER_NTFY,
    E2E_CALLER_TOD, E2E_CALLER_DOW, E2E_CALLER_RATELIMIT
  ].freeze

  def setup
    self.class.ensure_e2e_setup_once!
    purge_e2e_state!
  end

  def teardown
    purge_e2e_state!
  end

  class << self
    def ensure_e2e_setup_once!
      return if @setup_done
      ensure_e2e_tenant!
      ensure_e2e_phrases!
      @setup_done = true
    end

    def ensure_e2e_tenant!
      docker_runner(<<~RUBY)
        config = {
          email:                       "e2e@callscreen.test",
          password:                    SecureRandom.hex(32),
          name:                        "E2E test tenant",
          slug:                        "e2e",
          mobile_number:               "+390999000000",
          dedicated_number:            "+390999000000",  # routed by `to:` in webhooks
          forward_back_number:         "+390999000000",
          default_tenant:              false,
          admin:                       false,
          active:                      true,
          auto_detect_language:        true,
          greeting_voice:              "im_nicola",
          greeting_tone:               "natural",
          greeting_variant:            "informal_tu",
          greeting_language:           "it-IT",
          voice_rotation_enabled:      false,
          voice_rotation_voices:       nil,
          voice_rotation_index:        0,
          phrase_rotation_enabled:     false,
          phrase_rotation_index:       0,
          voice_clone_active:          false,
          ntfy_url:                    "disabled",
          spam_sensitivity:            0.5,
          max_calls_per_caller_per_day: 5,
          screening_speech_timeout:    "3",
          auto_blacklist_threshold:    nil,
          auto_blacklist_window_days:  7,
          railsdav_username:           nil,
          tod_morning_hour:            6,
          tod_afternoon_hour:          12,
          tod_evening_hour:            18,
          tod_night_hour:              22,
          time_zone:                   "Europe/Rome"
        }
        t = Tenant.find_by(slug: "e2e")
        if t
          attrs = config.except(:email, :password, :slug)
          t.update_columns(attrs)
        else
          Tenant.create!(config)
        end
      RUBY
    end

    def ensure_e2e_phrases!
      docker_runner(<<~RUBY)
        require "fileutils"
        tenant = Tenant.find_by!(slug: "e2e")
        spec = [
          [ "e2e_pool_specific", "any",     nil ],
          [ "e2e_morning",       "morning", nil ],
          [ "e2e_anytime",       "any",     nil ],
          [ "e2e_weekend",       "any",     "weekend" ],
          [ "e2e_anyday",        "any",     "any" ]
        ]
        spec.each do |slug, tod, dow|
          phrase = Phrase.find_or_create_by!(tenant_id: tenant.id, slug: slug) do |p|
            p.label   = slug.tr("_", " ")
            p.kind    = "user"
            p.text_it = "ciao e2e"
            p.text_en = "hi e2e"
            p.time_of_day = tod
            p.day_of_week = dow if dow
          end
          # Force into rendered status WITHOUT triggering the render job.
          updates = { render_status: "rendered", last_rendered_at: Time.current,
                      last_render_error: nil, time_of_day: tod }
          updates[:day_of_week] = dow if dow
          phrase.update_columns(updates)

          # Fake-write WAVs at every active-voice path so audio_url_for_voice
          # finds them. We cover the deterministic e2e voice + the rotation
          # voices used by test 03.
          [ "im_nicola", "if_sara" ].each do |voice|
            [ "natural", "slow" ].each do |tone|
              path = GreetingsStorage.path_for(slug, voice, tone)
              FileUtils.mkdir_p(File.dirname(path))
              File.binwrite(path, "RIFF e2e dummy wav")
            end
          end
        end
      RUBY
    end

    def docker_runner(snippet)
      raw = `docker exec -i callscreen bin/rails runner #{Shellwords.escape(snippet)} 2>&1`
      raise "docker_runner failed:\n#{raw}" unless $?.success?
      raw
    end
  end

  # === Per-test helpers ===

  def fire_call(from:, scenario: SyntheticCall::DEFAULT_SCENARIO, now: nil, recording_url: nil)
    SyntheticCall.fire(
      target:        TARGET,
      token:         TOKEN,
      from:          from,
      to:            E2E_TENANT_NUMBER,
      scenario:      scenario,
      now:           now,
      recording_url: recording_url,
      pause:         0.3
    )
  end

  # Read a Call from the inspector endpoint with a small retry loop —
  # the controller writes selected_phrase_slug synchronously inside the
  # webhook handler, but the HTTP response from synthetic_call returns
  # before disk-flush; retry briefly to absorb that.
  def read_call(call_control_id, retries: 6, delay: 0.4)
    retries.times do
      res = http_get_json_response("/e2e/call?call_control_id=#{URI.encode_www_form_component(call_control_id)}")
      return JSON.parse(res.body) if res.code == "200"
      sleep delay
    end
    raise "Call #{call_control_id} not visible after retries"
  end

  def read_tenant(slug)
    JSON.parse(http_get_json("/e2e/tenant?slug=#{URI.encode_www_form_component(slug)}"))
  end

  def read_contact(phone)
    res = http_get_json_response("/e2e/contact?phone=#{URI.encode_www_form_component(phone)}")
    return nil if res.code == "404"
    JSON.parse(res.body)
  end

  def http_get_json(path)
    res = http_get_json_response(path)
    raise "GET #{path} → HTTP #{res.code}: #{res.body[0, 200]}" unless res.code == "200"
    res.body
  end

  def http_get_json_response(path)
    sep = path.include?("?") ? "&" : "?"
    uri = URI("#{TARGET}#{path}#{sep}synthetic_token=#{URI.encode_www_form_component(TOKEN)}")
    Net::HTTP.get_response(uri)
  end

  def docker_runner(snippet)
    self.class.docker_runner(snippet)
  end

  # Phrase lookup helper used by language-swap and TOD/DOW tests.
  def read_phrase(slug)
    JSON.parse(docker_runner(<<~RUBY))
      p = Phrase.find_by(slug: #{slug.inspect})
      puts p ? p.attributes.to_json : "null"
    RUBY
  end

  def purge_e2e_state!
    docker_runner(<<~RUBY)
      tenant = Tenant.find_by(slug: "e2e")
      if tenant
        Call.where(tenant_id: tenant.id).delete_all
        tenant.contacts.update_all(
          whitelisted: false, blacklisted: false, phrase_rotation_index: 0
        )
        tenant.update_columns(
          voice_rotation_index: 0,
          phrase_rotation_index: 0,
          voice_rotation_enabled: false,
          voice_rotation_voices: nil
        )
      end
    RUBY
  end

  # Used by tests that need to set up a contact with assigned phrases.
  def assign_phrases_to_contact!(phone:, phrase_slugs:)
    docker_runner(<<~RUBY)
      tenant  = Tenant.find_by!(slug: "e2e")
      contact = tenant.contacts.find_or_create_by!(phone: #{phone.inspect})
      slugs   = #{phrase_slugs.inspect}
      phrases = Phrase.where(tenant_id: tenant.id, slug: slugs)
      contact.phrases = phrases
      contact.update_columns(phrase_rotation_index: 0)
    RUBY
  end

  def override_tenant!(updates)
    sets = updates.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
    docker_runner("Tenant.find_by!(slug: \"e2e\").update_columns(#{sets})")
  end
end

Minitest.after_run do
  if ENV["E2E_FULL_CLEANUP"] == "1"
    E2ETest.docker_runner(<<~RUBY)
      t = Tenant.find_by(slug: "e2e")
      if t
        t.calls.delete_all
        t.contacts.find_each do |c|
          c.contact_phrases.delete_all
          c.contact_tags.delete_all
          c.delete
        end
        t.phrases.find_each do |p|
          p.phrase_tags.delete_all
          p.tenant_phrases.delete_all
          p.contact_phrases.delete_all
          p.delete
        end
        t.tags.delete_all
        t.rules.delete_all
        AuditLog.where(tenant_id: t.id).delete_all
        t.delete
      end
    RUBY
  end
end
