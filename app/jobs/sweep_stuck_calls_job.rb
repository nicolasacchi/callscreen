# Finalizes calls stranded mid-flow. Outbound Call Control commands are
# best-effort (CallControlClient swallows errors so the webhook always 200s);
# if a command silently fails — Telnyx 5xx, our 5 s timeout — the call's
# flow_state advanced as if it succeeded but Telnyx never fires the follow-up
# event, so the leg hangs until the caller gives up. This sweep hangs up and
# marks done any non-terminal call that hasn't moved in a while, so a dropped
# command can't leave a caller in dead air indefinitely.
class SweepStuckCallsJob < ApplicationJob
  queue_as :default

  STUCK_AFTER = 10.minutes

  def perform(stuck_after: STUCK_AFTER)
    cutoff = stuck_after.ago
    Call.where.not(flow_state: "done")
        .where(hung_up_at: nil)
        .where(updated_at: ..cutoff)
        .find_each do |call|
      Rails.logger.warn("SweepStuckCallsJob: finalizing stuck call #{call.id} (flow_state=#{call.flow_state}, age=#{(Time.current - call.updated_at).to_i}s)")
      CallControlClient.new.hangup(call.call_control_id) if call.call_control_id.present?
      call.update!(flow_state: "done")
    end
  end
end
