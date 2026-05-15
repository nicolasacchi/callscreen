class RailsdavSpamReporter
  # POSTs a spam report to railsdav so the number is added to the
  # cross-tenant `spam_numbers` table. Mirrors `RailsdavContactsClient`'s
  # auth + timeout pattern — same Bearer token, same 3s timeout. Failures
  # are surfaced via `{ok: false}` so the ntfy controller can return
  # non-200 to the operator's phone instead of silently faking success.

  def self.report(phone, source: "ntfy_report", username: nil, notes: nil)
    new(phone, source: source, username: username, notes: notes).report
  end

  def initialize(phone, source:, username:, notes:)
    @phone    = phone.to_s
    @source   = source.to_s
    @username = username.to_s
    @notes    = notes.to_s
  end

  def report
    return failure("missing phone")    if @phone.blank?
    base  = ENV["RAILSDAV_API_URL"].to_s.strip.chomp("/")
    token = ENV["RAILSDAV_API_TOKEN"].to_s
    return failure("missing config")   if base.blank? || token.blank?

    body = { phone: @phone, source: @source }
    body[:submitted_by_username] = @username if @username.present?
    body[:notes]                 = @notes    if @notes.present?

    response = HTTParty.post(
      "#{base}/api/spam_reports",
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
      Rails.logger.warn("RailsdavSpamReporter post → #{response.code}: #{response.body.to_s.first(500)}")
      failure("http_#{response.code}")
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    Rails.logger.warn("RailsdavSpamReporter post failed: #{e.class}: #{e.message}")
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
