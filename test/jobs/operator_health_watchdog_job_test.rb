require "test_helper"

class OperatorHealthWatchdogJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @url = ENV["NTFY_URL"]
    NtfyNotifier.reset_failure_count!
    # Start from a clean slate so fixtures can't make "healthy" flaky.
    Phrase.where(render_status: "failed").update_all(render_status: "rendered")
  end

  test "no push when everything is healthy" do
    OperatorHealthWatchdogJob.new.perform
    assert_not_requested :post, /./
  end

  test "pushes a digest to the operator ntfy when calls have failed" do
    @tenant.calls.create!(call_sid: "hw-1", call_control_id: "hw-1",
                          from_number: "+390000000001", status: :failed)
    stub_request(:post, @url).to_return(status: 200)

    OperatorHealthWatchdogJob.new.perform

    assert_requested :post, @url do |req|
      req.headers["Title"].to_s.include?("problemi") && req.body.include?("Chiamate fallite")
    end
  end

  test "ignores failures older than the window" do
    old = @tenant.calls.create!(call_sid: "hw-2", call_control_id: "hw-2",
                                from_number: "+390000000002", status: :failed)
    old.update_columns(updated_at: 3.hours.ago)
    OperatorHealthWatchdogJob.new.perform
    assert_not_requested :post, /./
  end

  test "skips a backlog-drain run so a recovered stall can't flood the operator" do
    # A run enqueued long before it executes is one of the hourly jobs that piled
    # up while the worker was wedged, all draining at once. Even with a real
    # problem to report, it must NOT push — otherwise every backlogged hour fires
    # its own ntfy (the exact flood this guard removes).
    @tenant.calls.create!(call_sid: "hw-3", call_control_id: "hw-3",
                          from_number: "+390000000003", status: :failed)
    job = OperatorHealthWatchdogJob.new
    job.enqueued_at = 2.hours.ago
    job.perform
    assert_not_requested :post, /./
  end

  test "a run enqueued just now still pushes" do
    @tenant.calls.create!(call_sid: "hw-4", call_control_id: "hw-4",
                          from_number: "+390000000004", status: :failed)
    stub_request(:post, @url).to_return(status: 200)
    job = OperatorHealthWatchdogJob.new
    job.enqueued_at = 5.seconds.ago
    job.perform
    assert_requested :post, @url
  end

  # NB: the Solid Queue dead set and ready executions live in a separate queue
  # DB not present in the test connection (solid_queue_dead_count and
  # solid_queue_stale_ready_count are guarded + rescue to 0), so those counts
  # can't be exercised here — they mirror the failed_calls window above and are
  # verified against the live queue DB on deploy.

  test "alerts when railsdav is configured but unreachable" do
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "tok"
    stub_request(:get, "http://railsdav.test:3000/api/health").to_timeout
    stub_request(:post, @url).to_return(status: 200)

    OperatorHealthWatchdogJob.new.perform

    assert_requested(:post, @url) { |req| req.body.include?("Railsdav non raggiungibile") }
  ensure
    ENV["RAILSDAV_API_URL"] = ""
    ENV["RAILSDAV_API_TOKEN"] = ""
  end

  test "no alert when railsdav is reachable" do
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "tok"
    stub_request(:get, "http://railsdav.test:3000/api/health").to_return(status: 200, body: "{}")

    OperatorHealthWatchdogJob.new.perform

    assert_not_requested :post, /./
  ensure
    ENV["RAILSDAV_API_URL"] = ""
    ENV["RAILSDAV_API_TOKEN"] = ""
  end

  test "does not probe railsdav (no false alert) when it is not configured" do
    ENV["RAILSDAV_API_URL"] = ""
    OperatorHealthWatchdogJob.new.perform
    assert_not_requested :get, /api\/health/
    assert_not_requested :post, /./
  end
end
