# Reconciliation watchdog for screenings that captured a recording but were
# never classified or notified. P0-1 reordered the enqueue before the cosmetic
# goodbye, but a worker crash *between* the atomic recording claim and
# ScreeningJob.perform_later (or any future regression) still leaves a call with
# recording_url present, status :screening, notified_at nil, and NO queued job —
# invisible to SweepStuckCallsJob (which only hangs the leg up, never classifies)
# and to every other watchdog. This finds those and re-enqueues ScreeningJob.
#
# Idempotent: a duplicate run at worst re-pays Whisper + the LLM (bounded by the
# age cutoff); the eventual NotifyJob still only pushes once via its atomic
# notified_at claim. The age cutoff comfortably exceeds ScreeningJob's retry
# backoff (polynomial, 4 attempts ≈ a couple of minutes), so a legitimately
# in-flight or retrying screening is never re-enqueued under us.
class ReconcileStuckScreeningsJob < ApplicationJob
  queue_as :default

  STUCK_AFTER = 10.minutes

  def perform(stuck_after: STUCK_AFTER)
    Call.where(status: :screening, notified_at: nil)
        .where.not(recording_url: nil)
        .where(created_at: ..stuck_after.ago)
        .find_each do |call|
      Rails.logger.warn("ReconcileStuckScreeningsJob: re-enqueuing ScreeningJob for stranded call #{call.id} (age=#{(Time.current - call.created_at).to_i}s)")
      ScreeningJob.perform_later(call.id)
    end
  end
end
