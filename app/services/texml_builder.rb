class TexmlBuilder
  class << self
    def greeting_and_gather(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      greeting = Setting.get("greeting_text")
      timeout = Setting.get("screening_speech_timeout")

      wrap_response do |xml|
        xml << %(<Gather input="speech" speechTimeout="#{timeout}" language="#{language}" action="#{escape(action_url)}" method="POST">)
        xml << %(  <Say voice="#{voice}" language="#{language}">#{escape(greeting)}</Say>)
        xml << %(</Gather>)
        xml << %(<Say voice="#{voice}" language="#{language}">Non ho ricevuto risposta. Arrivederci.</Say>)
        xml << %(<Hangup/>)
      end
    end

    def record_voicemail(action_url:)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")
      prompt = Setting.get("voicemail_prompt")
      max_length = Setting.get("max_recording_seconds")

      wrap_response do |xml|
        xml << %(<Say voice="#{voice}" language="#{language}">#{escape(prompt)}</Say>)
        xml << %(<Record maxLength="#{max_length}" action="#{escape(action_url)}" playBeep="true" method="POST"/>)
      end
    end

    def forward_call(number)
      wrap_response do |xml|
        xml << %(<Dial>#{escape(number)}</Dial>)
      end
    end

    def hangup(message: nil)
      language = Setting.get("greeting_language")
      voice = Setting.get("greeting_voice")

      wrap_response do |xml|
        if message
          xml << %(<Say voice="#{voice}" language="#{language}">#{escape(message)}</Say>)
        end
        xml << %(<Hangup/>)
      end
    end

    def reject
      wrap_response do |xml|
        xml << %(<Reject/>)
      end
    end

    private

    def wrap_response
      lines = []
      yield lines
      body = lines.map { |l| "  #{l}" }.join("\n")
      %(<?xml version="1.0" encoding="UTF-8"?>\n<Response>\n#{body}\n</Response>)
    end

    def escape(text)
      text.to_s.encode(xml: :text)
    end
  end
end
