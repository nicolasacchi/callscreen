# Builds the public URL for a pre-rendered greeting/system phrase WAV for a
# specific (slug, voice, tone) — or nil when no rendered file exists (caller
# then falls back to Telnyx TTS). Extracted from TelnyxController's
# greeting_audio_url_for / audio_url_for_voice (ARCH-2); the dead pre-2026-05-07
# rotation/clone branch that ran when no voice: was given is gone — the voice is
# always chosen up front by VoiceSelector now, so a voice is required.
class GreetingAudioResolver
  def self.url(tenant:, slug:, voice:, language: nil)
    new(tenant).url(slug: slug, voice: voice, language: language)
  end

  # Raw per-voice URL with an EXPLICIT tone, skipping the Phrase/catalog slug
  # and tone allowlists. Used by the spam-response path, whose slugs come from
  # the hardcoded TROLL_SEGMENTS / "spam_disclose" (not user input), matching
  # the pre-extraction behavior of calling audio_url_for_voice directly.
  def self.url_for_voice(slug:, voice:, tone:, language: nil)
    for_voice(slug: slug, voice: voice, tone: tone, language: language)
  end

  def initialize(tenant)
    @tenant = tenant
  end

  # Resolves the picked voice, falling back to the tenant's default voice if the
  # picked voice has no rendered file for this slug/tone.
  def url(slug:, voice:, language: nil)
    return nil if slug.blank? || voice.blank?
    # Slug must reference a known Phrase (DB allowlist) or a catalog slug.
    return nil unless Phrase.where(slug: slug.to_s).exists? ||
                      GreetingCatalog::ALL_SLUGS.include?(slug.to_s)
    tone = @tenant.greeting_tone
    return nil unless GreetingCatalog::TONE_SLUGS.include?(tone.to_s)

    self.class.url_for_voice(slug: slug, voice: voice, tone: tone, language: language) ||
      self.class.url_for_voice(slug: slug, voice: @tenant.greeting_voice, tone: tone, language: language)
  end

  # URL for one specific (slug, voice, tone) combo if the rendered file exists.
  # Handles Kokoro voices (voice id encodes language) and cloned voices
  # (language encoded in the tone-filename suffix; served only with a signature
  # so the operator's voice WAVs aren't publicly harvestable).
  def self.for_voice(slug:, voice:, tone:, language:)
    return nil if voice.blank?
    voice_str = voice.to_s

    if voice_str.start_with?("_t")
      effective_voice = voice_str
      effective_tone  = (language && language != "it") ? "#{tone}_en" : tone
    else
      effective_voice = language ? GreetingCatalog.voice_for_language(voice_str, language) : voice_str
      effective_tone  = tone
      return nil unless Setting::ALLOWED_VOICES.include?(effective_voice)
    end

    return nil unless [ slug, effective_voice, effective_tone ].all? { |c| GreetingsStorage.safe_component?(c) }
    return nil unless GreetingsStorage.path_for(slug, effective_voice, effective_tone).exist?

    url = "#{ENV.fetch('APP_DOMAIN', 'https://example.com')}/greetings/#{slug}/#{effective_voice}/#{effective_tone}.wav"
    if effective_voice.start_with?("_t")
      sig = GreetingSignature.encode(slug: slug, voice: effective_voice, tone: effective_tone)
      url = "#{url}?sig=#{CGI.escape(sig)}"
    end
    url
  end
end
