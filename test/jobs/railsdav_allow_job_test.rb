require "test_helper"

class RailsdavAllowJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @call = @tenant.calls.create!(call_sid: "ra-1", call_control_id: "ra-1",
                                  from_number: "+393331234567", status: :legit)
  end

  test "maybe_enqueue is a no-op when railsdav is not configured" do
    ENV["RAILSDAV_API_URL"] = ""
    assert_no_enqueued_jobs only: RailsdavAllowJob do
      RailsdavAllowJob.maybe_enqueue(@call)
    end
  end

  test "maybe_enqueue is a no-op for a blank number" do
    ENV["RAILSDAV_API_URL"] = "http://railsdav.test:3000"
    @call.update_columns(from_number: "")
    assert_no_enqueued_jobs only: RailsdavAllowJob do
      RailsdavAllowJob.maybe_enqueue(@call)
    end
  ensure
    ENV["RAILSDAV_API_URL"] = ""
  end

  test "maybe_enqueue enqueues when railsdav is configured" do
    ENV["RAILSDAV_API_URL"] = "http://railsdav.test:3000"
    assert_enqueued_jobs 1, only: RailsdavAllowJob do
      RailsdavAllowJob.maybe_enqueue(@call)
    end
  ensure
    ENV["RAILSDAV_API_URL"] = ""
  end

  test "perform posts to upsert_allow and audits the railsdav ack" do
    ENV["RAILSDAV_API_URL"] = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "tok"
    stub_request(:post, "http://railsdav.test:3000/api/contacts/upsert_allow").to_return(status: 200, body: "{}")

    assert_difference -> { AuditLog.count } => 1 do
      RailsdavAllowJob.new.perform(@call.id)
    end
    log = AuditLog.recent.first
    assert_equal "railsdav_allow", log.action
    assert_equal true, log.metadata["railsdav_ack"]
  ensure
    ENV["RAILSDAV_API_URL"] = ""
    ENV["RAILSDAV_API_TOKEN"] = ""
  end
end
