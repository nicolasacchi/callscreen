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

    dead_set      = solid_queue_dead_count(since)
    failed_calls  = Call.where(status: :failed).where(updated_at: since..).count
    failed_renders = Phrase.where(render_status: "failed").where(updated_at: since..).count
    stuck_calls   = Call.where(flow_state: SweepStuckCallsJob::SWEEPABLE_STATES, hung_up_at: nil)
                        .where(created_at: ..SweepStuckCallsJob::STUCK_AFTER.ago).count
    # railsdav lookups degrade silently to MISS on any error, so an outage
    # quietly stops honoring central allow/block + global-spam with no symptom.
    # A reachability probe makes it a monitored dependency.
    railsdav_down = railsdav_configured? && !railsdav_reachable?

    # railsdav_down contributes no count, so fold it into the total or the
    # zero-guard below would suppress a reachability-only alert.
    total = dead_set + failed_calls + failed_renders + stuck_calls + (railsdav_down ? 1 : 0)
    return if total.zero?

    lines = []
    lines << "Railsdav non raggiungibile"                           if railsdav_down
    lines << "Job falliti (#{human_window}): #{dead_set}"           if dead_set.positive?
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

  # Count only failures within the trailing window — consistent with the other
  # metrics. The dead set ACCUMULATES (Solid Queue never auto-clears it), so
  # reporting the cumulative total made the digest cry the same stale number
  # every hour long after the operator had addressed (or cleared) it. Recent
  # failures are the actionable signal. Guard the constant so a future Solid
  # Queue rename can't crash the watchdog (it would just report 0).
  def solid_queue_dead_count(since)
    return 0 unless defined?(SolidQueue::FailedExecution)
    SolidQueue::FailedExecution.where(created_at: since..).count
  rescue StandardError => e
    Rails.logger.error("OperatorHealthWatchdogJob: dead-set count failed: #{e.class}: #{e.message}")
    0
  end

  # Only alert on unreachability when railsdav is actually configured — a
  # deployment with no RAILSDAV_API_URL intentionally runs without it.
  def railsdav_configured?
    ENV["RAILSDAV_API_URL"].to_s.strip.present? && ENV["RAILSDAV_API_TOKEN"].to_s.present?
  end

  # Off the call hot path (hourly :default job), so a generous timeout is fine —
  # too tight would produce false "non raggiungibile" alerts under load. Probes
  # the Bearer-gated /api/health endpoint.
  def railsdav_reachable?
    base = ENV["RAILSDAV_API_URL"].to_s.strip.chomp("/")
    response = HTTParty.get(
      "#{base}/api/health",
      headers: { "Authorization" => "Bearer #{ENV['RAILSDAV_API_TOKEN']}", "Accept" => "application/json" },
      timeout: 4
    )
    response.success?
  rescue StandardError => e
    Rails.logger.warn("OperatorHealthWatchdogJob: railsdav health probe failed: #{e.class}: #{e.message}")
    false
  end
end
