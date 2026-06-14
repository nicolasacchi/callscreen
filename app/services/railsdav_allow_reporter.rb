class RailsdavAllowReporter
  # Propagates an operator's "trust this caller" (whitelist) decision UP to
  # railsdav's shared address book via POST /api/contacts/upsert_allow, mirroring
  # RailsdavSpamReporter's auth + timeout. Best-effort: callers treat {ok:false}
  # as non-fatal — the LOCAL whitelist is the source of truth, railsdav is the
  # durable central echo.

  def self.report(phone, name: nil, username: nil)
    new(phone, name: name, username: username).report
  end

  def initialize(phone, name:, username:)
    @phone    = phone.to_s
    @name     = name.to_s
    @username = username.to_s
  end

  def report
    return failure("missing phone")  if @phone.blank?
    return failure("invalid_phone")  unless PhoneNumberNormalizer.e164(@phone)
    base  = ENV["RAILSDAV_API_URL"].to_s.strip.chomp("/")
    token = ENV["RAILSDAV_API_TOKEN"].to_s
    return failure("missing config") if base.blank? || token.blank?

    body = { phone: @phone }
    body[:name]     = @name     if @name.present?
    body[:username] = @username if @username.present?

    response = HTTParty.post(
      "#{base}/api/contacts/upsert_allow",
      body: body.to_json,
      headers: {
        "Authorization" => "Bearer #{token}",
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
        "X-Request-ID"  => Current.request_id.to_s
      },
      timeout: 3
    )

    if response.success?
      success
    else
      Rails.logger.warn("RailsdavAllowReporter post → #{response.code}: #{response.body.to_s.first(300)}")
      failure("http_#{response.code}")
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    Rails.logger.warn("RailsdavAllowReporter post failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    failure(e.class.name)
  end

  private

  def success
    { ok: true }
  end

  def failure(reason)
    { ok: false, error: reason }
  end
end
