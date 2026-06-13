require "test_helper"

# Rack::Attack throttles are abuse protection; a path typo or limit regression
# silently disables them. In the test env the default Rack::Attack store is the
# NullStore (counters never persist → throttles are no-ops), so we swap in a
# real MemoryStore for the duration of each test and restore it after.
class RackAttackTest < ActionDispatch::IntegrationTest
  setup do
    @original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rack::Attack.cache.store.clear
    Rack::Attack.cache.store = @original_store
  end

  test "admin login is throttled by submitted email after 5 attempts" do
    response_codes = Array.new(6) do
      post tenant_session_url, params: { tenant: { email: "throttle@example.test", password: "wrong" } }
      @response.response_code
    end
    assert_includes response_codes, 429, "the 6th same-email login attempt must be throttled"
    assert_response :too_many_requests
  end

  test "the telnyx webhook is throttled by IP past 60 req/min" do
    last = nil
    61.times do
      post telnyx_voice_url, params: "{}", headers: { "Content-Type" => "application/json" }
      last = @response.response_code
    end
    assert_equal 429, last
  end

  test "a single webhook request is not throttled (rejected by auth instead)" do
    post telnyx_voice_url, params: "{}", headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end
end
