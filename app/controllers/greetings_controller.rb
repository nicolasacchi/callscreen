class GreetingsController < ApplicationController
  GREETINGS_ROOT = Rails.root.join("storage", "greetings")
  SLUG_FORMAT = /\A[a-z0-9_]{1,40}\z/
  VOICE_FORMAT = /\A[a-z0-9_]{1,40}\z/

  # Public: Telnyx fetches greeting WAVs over the open internet to play in the
  # call. No auth — but the path is doubly regex-validated and resolved
  # against a static Rails.root prefix so traversal is impossible regardless
  # of what's in the DB.
  def show
    slug = params[:slug].to_s
    voice = params[:voice].to_s
    return head :not_found unless slug.match?(SLUG_FORMAT)
    return head :not_found unless voice.match?(VOICE_FORMAT)
    return head :not_found unless GreetingCatalog::SLUGS.include?(slug)
    return head :not_found unless Setting::ALLOWED_VOICES.include?(voice)

    path = GREETINGS_ROOT.join(slug, "#{voice}.wav")
    return head :not_found unless path.exist?

    send_file path, type: "audio/wav", disposition: :inline
  end
end
