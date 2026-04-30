# Sanity-check the env vars that gate outbound calls to railsdav-app's
# /api/contact_lookup. If only one of the pair is set, lookups silently
# fail-open (treated as no match), which can mask a misconfiguration; warn
# loudly at boot to surface it.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  url_set   = ENV["RAILSDAV_API_URL"].to_s.strip.present?
  token_set = ENV["RAILSDAV_API_TOKEN"].to_s.present?

  if url_set ^ token_set
    missing = url_set ? "RAILSDAV_API_TOKEN" : "RAILSDAV_API_URL"
    Rails.logger.warn(
      "[railsdav integration] #{missing} is not set; railsdav contact lookups will be skipped until both env vars are configured."
    )
  end
end
