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

  # Only these states indicate a dropped outbound command left the caller in
  # dead air with no follow-up event coming. We deliberately do NOT sweep
  # "bridged" (the caller is connected to the operator on a separate leg — that
  # conversation can run arbitrarily long and fires no webhook on this row) or
  # "recording" (a legacy voicemail can run up to max_recording_seconds).
  # Sweeping those would cut off live, legitimate calls.
  #
  # "transfer_dialing" IS swept: call.bridged moves a connected transfer to
  # "bridged" within timeout_secs (~15s), so a call left in transfer_dialing
  # past the cutoff is one whose transfer was accepted but never connected —
  # previously stranded forever (the leg fires no further event).
  SWEEPABLE_STATES = %w[
    answered
    screening_prompt_playing
    screening_recording
    transfer_dialing
    hanging_up_after_speak
    spam_disclose_playing
    troll_playing
  ].freeze

  def perform(stuck_after: STUCK_AFTER)
    cutoff = stuck_after.ago
    Call.where(flow_state: SWEEPABLE_STATES)
        .where(hung_up_at: nil)
        .where(updated_at: ..cutoff)
        .find_each do |call|
      Rails.logger.warn("SweepStuckCallsJob: finalizing stuck call #{call.id} (flow_state=#{call.flow_state}, age=#{(Time.current - call.updated_at).to_i}s)")
      CallControlClient.new.hangup(call.call_control_id) if call.call_control_id.present?
      call.update!(flow_state: "done")
    end
  end
end
