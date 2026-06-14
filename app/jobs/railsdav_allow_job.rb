# Propagates an operator whitelist UP to railsdav's central address book in the
# background (off the ntfy button / admin request path), mirroring
# ReportSpamGloballyJob. Best-effort + audited; the local whitelist already
# stands regardless of the outcome.
class RailsdavAllowJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Guard at the enqueue site: skip entirely when railsdav isn't configured, so
  # deployments without it don't accrue no-op jobs + failed-ack audit rows.
  def self.maybe_enqueue(call)
    return if call&.from_number.blank?
    return if ENV["RAILSDAV_API_URL"].to_s.strip.blank?
    perform_later(call.id)
  end

  def perform(call_id)
    call = Call.find(call_id)
    result = RailsdavAllowReporter.report(
      call.from_number,
      name:     call.contact&.name,
      username: call.tenant&.railsdav_username
    )
    AuditLog.record(action: "railsdav_allow", subject: call, tenant: call.tenant,
                    railsdav_ack: result[:ok] == true, railsdav_error: result[:error],
                    source: "ntfy", from: call.from_number)
    return if result[:ok]
    Rails.logger.warn("RailsdavAllowJob: allow propagation failed for call #{call_id}: #{result[:error]}")
  end
end
