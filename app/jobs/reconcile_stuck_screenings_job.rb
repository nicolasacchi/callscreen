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
  # Telnyx recording URLs (S3 pre-signed) expire. Re-enqueuing ScreeningJob for
  # a call older than this just 403s on download and pollutes the dead set, so
  # beyond it we finalize directly instead of re-attempting the download. (Normal
  # stuck calls are caught within ~15 min, while the URL is still valid.)
  RECORDING_FRESH_WITHIN = 24.hours

  def perform(stuck_after: STUCK_AFTER)
    Call.where(status: :screening, notified_at: nil)
        .where(created_at: ..stuck_after.ago)
        .find_each do |call|
      if call.recording_url.present? && call.created_at >= RECORDING_FRESH_WITHIN.ago
        # A recording was captured but the call was never classified (e.g. a
        # worker crash between the recording claim and ScreeningJob) and it is
        # still downloadable → re-enqueue ScreeningJob; its NotifyJob pushes once.
        Rails.logger.warn("ReconcileStuckScreeningsJob: re-enqueuing ScreeningJob for stranded call #{call.id} (age=#{(Time.current - call.created_at).to_i}s)")
        ScreeningJob.perform_later(call.id)
      else
        # Never recorded (caller hung up during the prompt) OR the recording is
        # too old to still download — either way it will never be classified.
        # Finalize so it leaves the :screening limbo (which also drops it from
        # this scope), and surface a push only for recent ones.
        finalize_unclassifiable(call)
      end
    end
  end

  private

  def finalize_unclassifiable(call)
    # A captured-but-now-inaccessible recording is a :voicemail (the operator can
    # at least see one arrived); a never-recorded screening is :unknown (a missed
    # call). NotifyJob then renders the right variant per status + recording_url.
    call.update!(status: call.recording_url.present? ? :voicemail : :unknown)
    return unless call.created_at >= NOTIFY_ABANDONED_WITHIN.ago
    Rails.logger.warn("ReconcileStuckScreeningsJob: notifying unclassifiable call #{call.id} (age=#{(Time.current - call.created_at).to_i}s)")
    NotifyJob.perform_later(call.id)
  end
end
