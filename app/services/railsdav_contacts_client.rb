class RailsdavContactsClient
  Result = Struct.new(:matched?, :name, :policy, :addressbook, :spam_global, :spam_metadata, keyword_init: true) do
    alias_method :match?, :matched?

    def spam_global?
      spam_global == true
    end
  end
  MISS = Result.new(matched?: false, name: nil, policy: nil, addressbook: nil, spam_global: false, spam_metadata: {}).freeze

  ALLOWED_POLICIES = %w[screen allow block].freeze
  MAX_STRING_LEN = 200
  SPAM_METADATA_KEYS = %w[first_reported_at source report_count].freeze
  # This lookup sits on the synchronous webhook hot path, in front of
  # cc_client.answer, holding one of only ~3 Puma threads. A tight timeout
  # bounds tail latency if railsdav is slow; the result degrades gracefully to
  # MISS (the local whitelist already covers the allow fast-path) (PERF-1).
  LOOKUP_TIMEOUT_SECS = Float(ENV.fetch("RAILSDAV_LOOKUP_TIMEOUT", "1.5"))

  def self.lookup(phone, username: nil)
    new(phone, username: username).lookup
  end

  def initialize(phone, username: nil)
    @phone    = phone.to_s
    @username = username.to_s
  end

  def lookup
    return MISS if @phone.blank?

    base  = ENV["RAILSDAV_API_URL"].to_s.strip.chomp("/")
    token = ENV["RAILSDAV_API_TOKEN"].to_s
    return MISS if base.blank? || token.blank?

    query = { phone: @phone }
    query[:username] = @username if @username.present?

    response = HTTParty.get(
      "#{base}/api/contact_lookup",
      query: query,
      headers: {
        "Authorization" => "Bearer #{token}",
        "Accept" => "application/json",
        "X-Request-ID" => Current.request_id.to_s
      },
      timeout: LOOKUP_TIMEOUT_SECS
    )

    return MISS unless response.success?

    body = response.parsed_response
    return MISS unless body.is_a?(Hash)

    spam_global   = body["spam_global"] == true
    spam_metadata = sanitize_spam_metadata(body["spam_metadata"])

    # Number is not in any address book but might still be in the global
    # spam DB — most spam calls fall in this branch. Return a Result with
    # `matched?: false` but `spam_global` populated, so TelnyxController's
    # priority-3.5 gate can fire on numbers we have no contact for.
    unless body["match"]
      return Result.new(
        matched?: false, name: nil, policy: nil, addressbook: nil,
        spam_global: spam_global, spam_metadata: spam_metadata
      )
    end

    policy = body["policy"].to_s
    policy = nil unless ALLOWED_POLICIES.include?(policy)

    Result.new(
      matched?: true,
      name: sanitize_string(body["name"]),
      policy: policy,
      addressbook: sanitize_string(body["addressbook"]),
      spam_global: spam_global,
      spam_metadata: spam_metadata
    )
  rescue Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    Rails.logger.warn("RailsdavContactsClient lookup failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    MISS
  end

  private

  # Strip control chars (CRLF, NUL, anything below 0x20 plus DEL) and cap
  # length. Defends against log/UI/ntfy injection if railsdav is ever
  # compromised or fed adversarial vCard input.
  def sanitize_string(value)
    return nil if value.nil?
    cleaned = value.to_s.gsub(/[\r\n\x00-\x1F\x7F]/, "").strip
    return nil if cleaned.empty?
    cleaned.first(MAX_STRING_LEN)
  end

  # Coerce the spam_metadata field into a Hash with only the expected keys.
  # Anything unrecognized is dropped so adversarial railsdav responses
  # cannot bleed extra fields into AuditLog or NtfyNotifier.
  def sanitize_spam_metadata(value)
    return {} unless value.is_a?(Hash)
    out = {}
    out["first_reported_at"] = sanitize_string(value["first_reported_at"]) if value["first_reported_at"]
    out["source"]            = sanitize_string(value["source"])            if value["source"]
    out["report_count"]      = value["report_count"].to_i                  if value["report_count"]
    out
  end
end
