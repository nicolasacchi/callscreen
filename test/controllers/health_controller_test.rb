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

  # Worker liveness — a stalled job fleet must surface as unhealthy even though
  # Puma still renders. Override the process table so the check is independent of
  # a live Solid Queue in the test env (same define_singleton_method + ensure
  # pattern as the primary-db test above).
  Fake = Struct.new(:kind, :last_heartbeat_at)

  test "GET /up returns 503 when every worker heartbeat is stale" do
    stub_processes([Fake.new("Worker", 10.minutes.ago)])
    get "/up"
    assert_response :service_unavailable
  ensure
    unstub_processes
  end

  test "GET /up returns 200 when a worker heartbeat is fresh" do
    stub_processes([Fake.new("Worker", 5.seconds.ago)])
    get "/up"
    assert_response :ok
  ensure
    unstub_processes
  end

  test "GET /up stays 200 during boot before any worker registers" do
    stub_processes([])
    get "/up"
    assert_response :ok
  ensure
    unstub_processes
  end

  test "GET /up stays 200 when the liveness probe itself errors (fail open)" do
    SolidQueue::Process.define_singleton_method(:all) { raise "queue db unreachable" }
    get "/up"
    assert_response :ok
  ensure
    unstub_processes
  end

  private

  def stub_processes(list)
    SolidQueue::Process.define_singleton_method(:all) { list }
  end

  def unstub_processes
    SolidQueue::Process.singleton_class.send(:remove_method, :all)
  end
end
