ENV["RAILS_ENV"] ||= "test"
ENV["WEBHOOK_TOKEN"] ||= "test-webhook-token"
ENV["APP_DOMAIN"] ||= "https://callscreen.test"
ENV["OPENROUTER_API_KEY"] ||= "test-openrouter-key"
ENV["OPENROUTER_MODEL"] ||= "anthropic/claude-sonnet-4-20250514"
ENV["TELNYX_API_KEY"] ||= "test-telnyx-key"
ENV["WHISPER_API_URL"] ||= "http://faster-whisper.test:8000"
ENV["NTFY_URL"] ||= "http://ntfy.test/callscreen"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    fixtures :all
  end
end
