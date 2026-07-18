# Liveness + readiness probe for the Docker/Traefik healthcheck at /up.
#
# Inherits ActionController::Base directly (NOT ApplicationController) so it
# skips `allow_browser versions: :modern` — otherwise curl's healthcheck
# request would be rejected with 406. Unlike rails/health#show (which only
# proves the process renders), this verifies the primary AND queue SQLite
# databases are reachable, so a wedged DB (busy-timeout exhaustion, WAL on a
# full disk) surfaces as an unhealthy container instead of a green 200
# (OPS-8). Kept cheap to stay under the 5 s healthcheck timeout.
class HealthController < ActionController::Base
  # No live Worker heartbeat within this window ⇒ the job fleet is stalled. Set
  # generous (≈5 missed 60 s heartbeats) so a busy moment can't flap the probe;
  # a real stall (SQLite lock storm, 2026-07-16) leaves heartbeats stale for
  # minutes-to-days.
  WORKER_STALE_AFTER = 5.minutes

  def show
    checks = { primary: db_ok?(ActiveRecord::Base) }
    checks[:queue]   = db_ok?(SolidQueue::Record) if defined?(SolidQueue::Record)
    checks[:workers] = workers_live?              if defined?(SolidQueue::Process)

    if checks.values.all?
      render plain: "OK", status: :ok
    else
      render plain: "FAIL #{checks.inspect}", status: :service_unavailable
    end
  end

  private

  def db_ok?(klass)
    klass.connection.select_value("SELECT 1").to_i == 1
  rescue StandardError => e
    Rails.logger.error("HealthController: #{klass} DB check failed: #{e.class}: #{e.message}")
    false
  end

  # A stalled job worker (SQLite lock storm, 2026-07-16) leaves Puma serving
  # HTTP while the default queue never drains — /up stayed a green 200 for
  # ~1.5 days and nothing recycled the container. Folding worker heartbeats into
  # the probe makes that state unhealthy so restart automation can recycle it.
  # Traefik routes on "container running", not Docker health, so a stale *job*
  # worker won't pull the *web* out of rotation and reject call webhooks.
  #
  # Fail OPEN: an empty process table means a fresh boot before the supervisor
  # registered (the healthcheck start_period covers it), and any unexpected
  # error must not take down an otherwise-healthy web — a genuinely unreachable
  # queue DB is already caught by the :queue check above. We only fail CLOSED on
  # a positive "processes exist but no Worker has a fresh heartbeat".
  def workers_live?
    processes = SolidQueue::Process.all.to_a
    return true if processes.empty?

    processes.any? do |process|
      process.kind == "Worker" &&
        process.last_heartbeat_at.present? &&
        process.last_heartbeat_at > WORKER_STALE_AFTER.ago
    end
  rescue StandardError => e
    Rails.logger.error("HealthController: worker liveness check failed: #{e.class}: #{e.message}")
    true
  end
end
