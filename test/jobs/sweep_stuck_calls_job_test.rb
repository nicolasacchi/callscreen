require "test_helper"

class SweepStuckCallsJobTest < ActiveJob::TestCase
  setup { @tenant = tenants(:default) }

  test "finalizes a call stranded mid-flow and hangs it up" do
    hangup = stub_request(:post, %r{api\.telnyx\.com/v2/calls/.+/actions/hangup})
             .to_return(status: 200, body: "{}")
    stuck = @tenant.calls.create!(
      call_sid: "v3:stuck-1", call_control_id: "v3:stuck-1",
      from_number: "+390000000001", status: :screening, flow_state: "screening_recording"
    )
    stuck.update_columns(updated_at: 30.minutes.ago)

    SweepStuckCallsJob.new.perform

    assert_equal "done", stuck.reload.flow_state
    assert_requested hangup
  end

  test "leaves recent and already-done calls untouched" do
    recent = @tenant.calls.create!(
      call_sid: "v3:recent-1", call_control_id: "v3:recent-1",
      from_number: "+390000000002", status: :screening, flow_state: "screening_recording"
    )
    done = @tenant.calls.create!(
      call_sid: "v3:done-1", call_control_id: "v3:done-1",
      from_number: "+390000000003", status: :completed, flow_state: "done"
    )
    done.update_columns(updated_at: 30.minutes.ago)

    # No hangup stub: if the sweep touched either call, WebMock would raise.
    SweepStuckCallsJob.new.perform

    assert_equal "screening_recording", recent.reload.flow_state
    assert_equal "done", done.reload.flow_state
  end

  test "does NOT hang up a long-running bridged call" do
    # A connected transfer is moved to "bridged" by call.bridged; that
    # conversation runs arbitrarily long and fires no webhook on this leg, so
    # the sweep must leave it alone.
    bridged = @tenant.calls.create!(
      call_sid: "v3:bridged-1", call_control_id: "v3:bridged-1",
      from_number: "+390000000004", status: :legit, flow_state: "bridged"
    )
    bridged.update_columns(updated_at: 30.minutes.ago)

    # No hangup stub: a hangup attempt would raise on the unstubbed POST.
    SweepStuckCallsJob.new.perform

    assert_equal "bridged", bridged.reload.flow_state
  end

  test "hangs up a transfer stuck in transfer_dialing (never bridged)" do
    # A transfer accepted by Telnyx but never connected stays transfer_dialing
    # with no further event — previously stranded forever. Now sweepable.
    hangup = stub_request(:post, %r{api\.telnyx\.com/v2/calls/.+/actions/hangup})
             .to_return(status: 200, body: "{}")
    stuck = @tenant.calls.create!(
      call_sid: "v3:dialing-1", call_control_id: "v3:dialing-1",
      from_number: "+390000000005", status: :legit, flow_state: "transfer_dialing"
    )
    stuck.update_columns(updated_at: 30.minutes.ago)

    SweepStuckCallsJob.new.perform

    assert_equal "done", stuck.reload.flow_state
    assert_requested hangup
  end
end
