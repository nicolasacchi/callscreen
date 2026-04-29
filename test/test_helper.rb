ENV["RAILS_ENV"] ||= "test"
ENV["WEBHOOK_TOKEN"] ||= "test-webhook-token"
# Keep token-fallback enabled in tests so existing webhook tests using ?token=
# continue to work without fabricating Ed25519 signatures everywhere.
# Tests that exercise signature verification override this explicitly.
ENV["WEBHOOK_TOKEN_FALLBACK"] ||= "1"
ENV["APP_DOMAIN"] ||= "https://callscreen.test"
ENV["MOONSHOT_API_KEY"] ||= "test-moonshot-key"
ENV["MOONSHOT_MODEL"] ||= "kimi-k2.6"
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
