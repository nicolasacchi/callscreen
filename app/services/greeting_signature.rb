# Signs cloned-voice greeting URLs. Kokoro/Chatterbox catalog voices are served
# publicly (they're generic TTS voices), but a tenant's CLONED voice (_t<id>)
# is the operator's own voice and is treated as sensitive elsewhere (the
# spam-response path deliberately never plays it to known-bad callers, to avoid
# handing a clean voice sample to a fraudster). So cloned-voice greeting URLs
# carry a signature that GreetingsController verifies — Telnyx can fetch the
# exact URL we generated, but the file can't be harvested by guessing
# slug/tenant-id/tone. The signature binds the path triple, so a token for one
# greeting can't be replayed for another.
class GreetingSignature
  PURPOSE = "greeting_audio".freeze

  def self.encode(slug:, voice:, tone:)
    verifier.generate(payload(slug, voice, tone), purpose: PURPOSE)
  end

  def self.valid?(token, slug:, voice:, tone:)
    return false if token.blank?
    verifier.verified(token.to_s, purpose: PURPOSE) == payload(slug, voice, tone)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def self.payload(slug, voice, tone)
    "#{slug}/#{voice}/#{tone}"
  end

  def self.verifier
    Rails.application.message_verifier(:greeting_audio)
  end
end
