require "test_helper"

class ReconcileStuckScreeningsJobTest < ActiveJob::TestCase
  setup { @tenant = tenants(:default) }

  def stranded(sid, **attrs)
    call = @tenant.calls.create!(
      call_sid: sid, call_control_id: sid, from_number: "+390000000000",
      status: :screening, recording_url: "https://x/#{sid}.wav",
      flow_state: "hanging_up_after_speak", **attrs
    )
    call.update_columns(created_at: 20.minutes.ago)
    call
  end

  test "re-enqueues ScreeningJob for a stranded screening (recording present, unnotified, old)" do
    stranded("rs-1")
    assert_enqueued_jobs 1, only: ScreeningJob do
      ReconcileStuckScreeningsJob.new.perform
    end
  end

  test "leaves a recent screening alone (still within the cutoff)" do
    @tenant.calls.create!(call_sid: "rs-2", call_control_id: "rs-2", from_number: "+390000000002",
                          status: :screening, recording_url: "https://x/a.wav")
    assert_no_enqueued_jobs only: ScreeningJob do
      ReconcileStuckScreeningsJob.new.perform
    end
  end

  test "leaves an already-notified screening alone" do
    stranded("rs-3", notified_at: Time.current)
    assert_no_enqueued_jobs only: ScreeningJob do
      ReconcileStuckScreeningsJob.new.perform
    end
  end

  test "leaves a recent (within-cutoff) no-recording screening alone" do
    @tenant.calls.create!(call_sid: "rs-4", call_control_id: "rs-4", from_number: "+390000000004",
                          status: :screening, recording_url: nil)
    assert_no_enqueued_jobs only: NotifyJob do
      ReconcileStuckScreeningsJob.new.perform
    end
  end

  test "finalizes a recent recording-less stuck screening as :unknown and notifies (abandoned at screening)" do
    call = @tenant.calls.create!(call_sid: "rs-4a", call_control_id: "rs-4a", from_number: "+390000000041",
                                 status: :screening, recording_url: nil)
    call.update_columns(created_at: 20.minutes.ago)
    assert_enqueued_jobs 1, only: NotifyJob do
      ReconcileStuckScreeningsJob.new.perform
    end
    assert_equal "unknown", call.reload.status
  end

  test "finalizes a STALE recording-less stuck screening silently (drains backlog, no push)" do
    call = @tenant.calls.create!(call_sid: "rs-4b", call_control_id: "rs-4b", from_number: "+390000000042",
                                 status: :screening, recording_url: nil)
    call.update_columns(created_at: 3.hours.ago)
    assert_no_enqueued_jobs only: NotifyJob do
      ReconcileStuckScreeningsJob.new.perform
    end
    assert_equal "unknown", call.reload.status
  end

  test "leaves an already-classified call alone" do
    call = @tenant.calls.create!(call_sid: "rs-5", call_control_id: "rs-5", from_number: "+390000000005",
                                 status: :legit, recording_url: "https://x/a.wav")
    call.update_columns(created_at: 20.minutes.ago)
    assert_no_enqueued_jobs only: ScreeningJob do
      ReconcileStuckScreeningsJob.new.perform
    end
  end
end
