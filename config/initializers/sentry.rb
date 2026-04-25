module SentryPiiScrubber
  PII_KEYS = %w[
    From To CallSid SpeechResult RecordingUrl
    phone transcript screening_transcript voicemail_transcript name
  ].freeze

  def self.scrub!(data)
    return unless data.is_a?(Hash)
    PII_KEYS.each { |key| data[key] = "[FILTERED]" if data.key?(key) }
    data
  end
end

if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
    config.environment = Rails.env
    config.send_default_pii = false

    # Drop PII from any event before sending. Rails already filters request
    # params via filter_parameter_logging, but breadcrumbs / extras can still
    # carry caller phone numbers or transcripts.
    config.before_send = lambda do |event, _hint|
      SentryPiiScrubber.scrub!(event.request&.data) if event.respond_to?(:request) && event.request
      event
    end

    config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.0").to_f
  end
end
