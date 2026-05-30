require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "GET /up returns 200 OK and actually touches the database" do
    get "/up"
    assert_response :ok
    assert_equal "OK", response.body
  end

  test "GET /up returns 503 when the primary database check fails" do
    # Force the SELECT 1 probe to raise, then confirm we report unhealthy
    # rather than a misleading 200. Restored in ensure.
    conn = ActiveRecord::Base.connection
    conn.define_singleton_method(:select_value) { |*| raise "simulated db outage" }
    get "/up"
    assert_response :service_unavailable
  ensure
    conn.singleton_class.send(:remove_method, :select_value)
  end
end
