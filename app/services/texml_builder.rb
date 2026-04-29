require "nokogiri"

class TexmlBuilder
  class << self
    def greeting_and_gather(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      greeting = Setting.get("greeting_text")
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
          xml.Say(greeting, voice: voice, language: language)
        end
        xml.Say("Non ho ricevuto risposta. Arrivederci.", voice: voice, language: language)
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
        xml.Record(maxLength: max_length, action: action_url, playBeep: "true", method: "POST")
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

    private

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
