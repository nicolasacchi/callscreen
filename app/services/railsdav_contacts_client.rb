class RailsdavContactsClient
  Result = Struct.new(:matched?, :name, :policy, :addressbook, keyword_init: true) do
    alias_method :match?, :matched?
  end
  MISS = Result.new(matched?: false, name: nil, policy: nil, addressbook: nil).freeze

  ALLOWED_POLICIES = %w[screen allow block].freeze
  MAX_STRING_LEN = 200

  def self.lookup(phone)
    new(phone).lookup
  end

  def initialize(phone)
    @phone = phone.to_s
  end

  def lookup
    return MISS if @phone.blank?

    base = ENV["RAILSDAV_API_URL"].to_s.strip.chomp("/")
    token = ENV["RAILSDAV_API_TOKEN"].to_s
    return MISS if base.blank? || token.blank?

    response = HTTParty.get(
      "#{base}/api/contact_lookup",
      query: { phone: @phone },
      headers: {
        "Authorization" => "Bearer #{token}",
        "Accept" => "application/json",
        "X-Request-ID" => Current.request_id.to_s
      },
      timeout: 3
    )

    return MISS unless response.success?

    body = response.parsed_response
    return MISS unless body.is_a?(Hash) && body["match"]

    policy = body["policy"].to_s
    policy = nil unless ALLOWED_POLICIES.include?(policy)

    Result.new(
      matched?: true,
      name: sanitize_string(body["name"]),
      policy: policy,
      addressbook: sanitize_string(body["addressbook"])
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
end
