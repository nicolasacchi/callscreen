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
    return head :not_found unless GreetingCatalog::ALL_SLUGS.include?(slug)
    return head :not_found unless Setting::ALLOWED_VOICES.include?(voice)
    return head :not_found unless GreetingCatalog::TONE_SLUGS.include?(tone)

    path = GreetingsStorage.path_for(slug, voice, tone)
    return head :not_found unless path.exist?

    send_file path, type: "audio/wav", disposition: :inline
  end
end
