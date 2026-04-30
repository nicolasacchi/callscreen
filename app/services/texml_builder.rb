require "nokogiri"

class TexmlBuilder
  class << self
    def greeting_and_gather(action_url:, tenant: nil)
      tenant ||= Tenant.default
      language = tenant&.greeting_language.presence || Setting.get("greeting_language")
      voice    = tenant&.greeting_voice.presence    || Setting.get("greeting_voice")
      slug     = tenant&.greeting_variant.presence  || Setting.get("greeting_variant")
      tone     = tenant&.greeting_tone.presence     || Setting.get("greeting_tone")
      speech_timeout = tenant&.screening_speech_timeout.presence || Setting.get("screening_speech_timeout")
      engine   = Setting.get("transcription_engine")

      build_response do |xml|
        xml.Gather(
          input: "speech",
          timeout: 10,
          speechTimeout: speech_timeout,
          language: language,
          transcriptionEngine: engine,
          action: action_url,
          method: "POST"
        ) do
          render_greeting(xml, slug: slug, voice: voice, tone: tone, language: language, tenant: tenant)
        end
        render_system_phrase(xml, "no_answer", voice: voice, tone: tone, language: language)
        xml.Hangup
      end
    end

    def record_voicemail(action_url:, tenant: nil)
      tenant ||= Tenant.default
      language   = tenant&.greeting_language.presence || Setting.get("greeting_language")
      voice      = tenant&.greeting_voice.presence    || Setting.get("greeting_voice")
      tone       = tenant&.greeting_tone.presence     || Setting.get("greeting_tone")
      max_length = tenant&.max_recording_seconds      || Setting.get("max_recording_seconds")

      build_response do |xml|
        render_system_phrase(xml, "voicemail_prompt", voice: voice, tone: tone, language: language)
        xml.Record(
          maxLength: max_length,
          timeout: 5,
          action: action_url,
          recordingStatusCallback: action_url,
          playBeep: "true",
          method: "POST"
        )
      end
    end

    def forward_call(number)
      build_response do |xml|
        # timeout=15 must stay BELOW the carrier's no-answer-forward threshold
        # (typically 20-25s on Italian mobile carriers) so the Dial-back gives
        # up before the carrier re-forwards the call to the Telnyx number,
        # which would create a loop.
        xml.Dial(number, timeout: 15)
      end
    end

    # Hangup with an optional pre-rendered system-phrase preface.
    #   phrase: a key in GreetingCatalog::SYSTEM_PHRASES (e.g. "goodbye_spam")
    # When phrase is nil, just emits <Hangup/>.
    def hangup(phrase: nil, tenant: nil)
      tenant ||= Tenant.default
      language = tenant&.greeting_language.presence || Setting.get("greeting_language")
      voice    = tenant&.greeting_voice.presence    || Setting.get("greeting_voice")
      tone     = tenant&.greeting_tone.presence     || Setting.get("greeting_tone")

      build_response do |xml|
        render_system_phrase(xml, phrase, voice: voice, tone: tone, language: language) if phrase
        xml.Hangup
      end
    end

    def reject
      build_response do |xml|
        xml.Reject
      end
    end

    # One-shot follow-up Gather for ambiguous calls. Plays a pre-rendered
    # "please clarify" prompt in the same voice as the greeting, then
    # captures a second utterance via Gather.
    def clarify_and_gather(action_url:, tenant: nil)
      tenant ||= Tenant.default
      language = tenant&.greeting_language.presence || Setting.get("greeting_language")
      voice    = tenant&.greeting_voice.presence    || Setting.get("greeting_voice")
      tone     = tenant&.greeting_tone.presence     || Setting.get("greeting_tone")
      speech_timeout = tenant&.screening_speech_timeout.presence || Setting.get("screening_speech_timeout")
      engine   = Setting.get("transcription_engine")

      build_response do |xml|
        xml.Gather(
          input: "speech",
          timeout: 10,
          speechTimeout: speech_timeout,
          language: language,
          transcriptionEngine: engine,
          action: action_url,
          method: "POST"
        ) do
          render_clarification(xml, voice: voice, tone: tone, language: language)
        end
        xml.Say("Non ho ricevuto risposta. Arrivederci.", voice: "alice", language: language)
        xml.Hangup
      end
    end

    private

    def render_clarification(xml, voice:, tone:, language:)
      render_system_phrase(xml, "clarify", voice: voice, tone: tone, language: language)
    end

    # Generic helper: emit <Play> against pre-rendered Kokoro audio if it
    # exists, otherwise fall back to <Say voice="alice"> with the literal
    # text (Telnyx's built-in voice — the only voice the system can fall
    # back on safely without producing English-accented Italian).
    def render_system_phrase(xml, slug, voice:, tone:, language:)
      return unless slug

      audio_path = greeting_audio_path(slug, voice, tone)
      if audio_path&.exist?
        xml.Play(greeting_audio_url(slug, voice, tone))
      else
        text = GreetingCatalog::SYSTEM_PHRASES[slug.to_s]
        xml.Say(text, voice: "alice", language: language) if text
      end
    end

    def render_greeting(xml, slug:, voice:, tone:, language:, tenant: nil)
      audio_path = greeting_audio_path(slug, voice, tone)
      if audio_path&.exist?
        xml.Play(greeting_audio_url(slug, voice, tone))
      else
        text = GreetingCatalog.text_for(slug) ||
               tenant&.greeting_text.presence ||
               Setting.get("greeting_text")
        xml.Say(text, voice: "alice", language: language)
      end
    end

    def greeting_audio_path(slug, voice, tone)
      return nil unless GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
      return nil unless Setting::ALLOWED_VOICES.include?(voice.to_s)
      return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)
      GreetingsStorage.path_for(slug, voice, tone)
    end

    def greeting_audio_url(slug, voice, tone)
      app_domain = ENV.fetch("APP_DOMAIN", "https://phone.example.com")
      "#{app_domain}/greetings/#{slug}/#{voice}/#{tone}.wav"
    end

    def build_response
      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.Response do
          yield xml
        end
      end
      builder.to_xml
    end
  end
end
