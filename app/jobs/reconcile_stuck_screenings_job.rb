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
  # Abandoned-at-screening calls older than this are finalized SILENTLY — a
  # historical backlog (or a long outage) must not blast a storm of stale
  # missed-call pushes. Anything more recent gets one low-priority push.
  NOTIFY_ABANDONED_WITHIN = 1.hour

  def perform(stuck_after: STUCK_AFTER)
    # Branch 1: a recording WAS captured but the call was never classified
    # (e.g. a worker crash between the recording claim and ScreeningJob).
    # Re-enqueue ScreeningJob; its eventual NotifyJob still pushes once.
    Call.where(status: :screening, notified_at: nil)
        .where.not(recording_url: [ nil, "" ])
        .where(created_at: ..stuck_after.ago)
        .find_each do |call|
      Rails.logger.warn("ReconcileStuckScreeningsJob: re-enqueuing ScreeningJob for stranded call #{call.id} (age=#{(Time.current - call.created_at).to_i}s)")
      ScreeningJob.perform_later(call.id)
    end

    # Branch 2: the call reached screening but NO recording ever arrived — the
    # caller hung up during the prompt. It will never be classified, so finalize
    # it as :unknown (which also removes it from this scope so it isn't re-swept)
    # and surface a missed-call push for recent ones. handle_hangup already
    # finalizes the common pre-recording case instantly; this is the safety net
    # (e.g. a hangup during screening_recording where no recording followed) plus
    # the one-time drain of the historical backlog.
    Call.where(status: :screening, notified_at: nil)
        .where(recording_url: [ nil, "" ])
        .where(created_at: ..stuck_after.ago)
        .find_each do |call|
      recent = call.created_at >= NOTIFY_ABANDONED_WITHIN.ago
      call.update!(status: :unknown)
      next unless recent
      Rails.logger.warn("ReconcileStuckScreeningsJob: notifying abandoned-at-screening call #{call.id} (age=#{(Time.current - call.created_at).to_i}s)")
      NotifyJob.perform_later(call.id)
    end
  end
end
