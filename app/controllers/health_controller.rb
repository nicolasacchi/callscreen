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
  def show
    checks = { primary: db_ok?(ActiveRecord::Base) }
    checks[:queue] = db_ok?(SolidQueue::Record) if defined?(SolidQueue::Record)

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
end
