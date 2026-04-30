require "nokogiri"

class TexmlBuilder
  class << self
    def greeting_and_gather(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      slug = Setting.get("greeting_variant")
      tone = Setting.get("greeting_tone")
      speech_timeout = Setting.get("screening_speech_timeout")
      engine = Setting.get("transcription_engine")

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
          render_greeting(xml, slug: slug, voice: voice, tone: tone, language: language)
        end
        xml.Say("Non ho ricevuto risposta. Arrivederci.", voice: "alice", language: language)
        xml.Hangup
      end
    end

    def record_voicemail(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      prompt = Setting.get("voicemail_prompt")
      max_length = Setting.get("max_recording_seconds")

      build_response do |xml|
        xml.Say(prompt, voice: voice, language: language)
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
        xml.Dial(number)
      end
    end

    def hangup(message: nil)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")

      build_response do |xml|
        xml.Say(message, voice: voice, language: language) if message
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
    def clarify_and_gather(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      tone = Setting.get("greeting_tone")
      speech_timeout = Setting.get("screening_speech_timeout")
      engine = Setting.get("transcription_engine")

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
      audio_path = greeting_audio_path("clarify", voice, tone)
      if audio_path&.exist?
        xml.Play(greeting_audio_url("clarify", voice, tone))
      else
        xml.Say(
          GreetingCatalog::SYSTEM_PHRASES["clarify"],
          voice: "alice",
          language: language
        )
      end
    end

    def render_greeting(xml, slug:, voice:, tone:, language:)
      audio_path = greeting_audio_path(slug, voice, tone)
      if audio_path&.exist?
        xml.Play(greeting_audio_url(slug, voice, tone))
      else
        text = GreetingCatalog.text_for(slug) || Setting.get("greeting_text")
        xml.Say(text, voice: "alice", language: language)
      end
    end

    def greeting_audio_path(slug, voice, tone)
      return nil unless GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
      return nil unless Setting::ALLOWED_VOICES.include?(voice.to_s)
      return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)
      Rails.root.join("storage", "greetings", slug.to_s, voice.to_s, "#{tone}.wav")
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
