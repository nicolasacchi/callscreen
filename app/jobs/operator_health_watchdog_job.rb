# Aggregate health watchdog. Per-event Sentry capture exists throughout, but
# nothing tells the operator when failures ACCUMULATE — a systemic
# Telnyx/Whisper/TTS problem or a growing Solid Queue dead set otherwise
# produces only log lines no one watches. This runs hourly, tallies failures
# over the trailing window, and pushes a single digest to the OPERATOR ntfy
# (the ENV default, never a tenant url — so it bypasses the per-tenant
# "disabled" opt-out the e2e tenant uses).
class OperatorHealthWatchdogJob < ApplicationJob
  queue_as :default

  WINDOW = 1.hour

  def perform(window: WINDOW)
    since = window.ago

    dead_set      = solid_queue_dead_count
    failed_calls  = Call.where(status: :failed).where(updated_at: since..).count
    failed_renders = Phrase.where(render_status: "failed").where(updated_at: since..).count
    stuck_calls   = Call.where(flow_state: SweepStuckCallsJob::SWEEPABLE_STATES, hung_up_at: nil)
                        .where(created_at: ..SweepStuckCallsJob::STUCK_AFTER.ago).count

    total = dead_set + failed_calls + failed_renders + stuck_calls
    return if total.zero?

    lines = []
    lines << "Dead-set jobs: #{dead_set}"               if dead_set.positive?
    lines << "Chiamate fallite (#{human_window}): #{failed_calls}"   if failed_calls.positive?
    lines << "Render falliti (#{human_window}): #{failed_renders}"   if failed_renders.positive?
    lines << "Chiamate bloccate: #{stuck_calls}"        if stuck_calls.positive?

    Rails.logger.warn("OperatorHealthWatchdogJob: #{lines.join('; ')}")
    NtfyNotifier.notify(
      title: "⚠️ Callscreen: #{total} problemi rilevati",
      message: lines.join("\n"),
      priority: "high",
      tags: [ "warning" ]
      # No url:/tenant_priority: → NtfyNotifier falls back to ENV["NTFY_URL"],
      # the operator's own endpoint.
    )
  end

  private

  def human_window
    "ultima ora"
  end

  # The dead set lives in Solid Queue's own tables. Guard the constant so a
  # future Solid Queue rename can't crash the watchdog (it would just report 0).
  def solid_queue_dead_count
    return 0 unless defined?(SolidQueue::FailedExecution)
    SolidQueue::FailedExecution.count
  rescue StandardError => e
    Rails.logger.error("OperatorHealthWatchdogJob: dead-set count failed: #{e.class}: #{e.message}")
    0
  end
end
