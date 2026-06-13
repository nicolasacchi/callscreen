require "test_helper"

class ReportSpamGloballyJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @call = @tenant.calls.create!(call_sid: "rg-1", call_control_id: "rg-1",
                                  from_number: "+393331112222", status: :spam)
  end

  test "maybe_enqueue is a no-op when the tenant has not opted in" do
    @tenant.update!(auto_report_spam_globally: false)
    assert_no_enqueued_jobs only: ReportSpamGloballyJob do
      ReportSpamGloballyJob.maybe_enqueue(@call)
    end
  end

  test "maybe_enqueue enqueues when the tenant opted in" do
    @tenant.update!(auto_report_spam_globally: true)
    assert_enqueued_jobs 1, only: ReportSpamGloballyJob do
      ReportSpamGloballyJob.maybe_enqueue(@call)
    end
  end

  test "maybe_enqueue is a no-op for a nil call or blank number" do
    @tenant.update!(auto_report_spam_globally: true)
    assert_no_enqueued_jobs only: ReportSpamGloballyJob do
      ReportSpamGloballyJob.maybe_enqueue(nil)
    end
  end

  test "perform POSTs the number to railsdav" do
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "tok"
    stub = stub_request(:post, "http://railsdav.test:3000/api/spam_reports").to_return(status: 200, body: "{}")
    ReportSpamGloballyJob.new.perform(@call.id)
    assert_requested stub
  ensure
    ENV.delete("RAILSDAV_API_URL")
    ENV.delete("RAILSDAV_API_TOKEN")
  end
end
