class GreetingsController < ApplicationController
  SLUG_FORMAT = /\A[a-z0-9_]{1,40}\z/
  VOICE_FORMAT = /\A[a-z0-9_]{1,40}\z/
  TONE_FORMAT = /\A[a-z0-9_]{1,40}\z/

  # Public: Telnyx fetches greeting WAVs over the open internet to play in the
  # call. No auth — but each path component is doubly regex-validated and
  # then allowlisted, so traversal is impossible regardless of what's in the
  # DB.
  def show
    slug = params[:slug].to_s
    voice = params[:voice].to_s
    tone = params[:tone].to_s
    return head :not_found unless slug.match?(SLUG_FORMAT)
    return head :not_found unless voice.match?(VOICE_FORMAT)
    return head :not_found unless tone.match?(TONE_FORMAT)
    # Slug allowlist is now DB-backed: any seeded shared phrase or any
    # tenant-authored phrase is valid. The format regex above still
    # blocks path traversal — this exists?-call only checks identity.
    return head :not_found unless Phrase.exists?(slug: slug)
    return head :not_found unless valid_voice_and_tone?(slug, voice, tone)

    path = GreetingsStorage.path_for(slug, voice, tone)
    return head :not_found unless path.exist?

    send_file path, type: "audio/wav", disposition: :inline
  end

  private

  # Cloned-voice greetings (_t<id>) are served only with a valid signature (see
  # GreetingSignature); catalog voices stay public. The tone may carry an `_en`
  # suffix for cloned English audio, so validate against the base tone.
  def valid_voice_and_tone?(slug, voice, tone)
    base_tone = tone.sub(/_en\z/, "")
    return false unless GreetingCatalog::TONE_SLUGS.include?(base_tone)

    if voice.match?(/\A_t\d+\z/)
      GreetingSignature.valid?(params[:sig], slug: slug, voice: voice, tone: tone)
    else
      Setting::ALLOWED_VOICES.include?(voice)
    end
  end
end
