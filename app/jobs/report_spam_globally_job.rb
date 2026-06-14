# Auto-contributes an operator-confirmed spam number to the shared railsdav
# reputation DB (P2-7). Runs in the background — RailsdavSpamReporter is a
# synchronous HTTP POST that must never sit on a request/webhook path. Only
# enqueued when the tenant has opted in (auto_report_spam_globally).
class ReportSpamGloballyJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Guard at the enqueue site so callers don't repeat the opt-in/blank checks.
  def self.maybe_enqueue(call)
    return unless call&.tenant&.auto_report_spam_globally?
    return if call.from_number.blank?
    perform_later(call.id)
  end

  def perform(call_id)
    call = Call.find(call_id)
    # railsdav only accepts a source in its SOURCES_WHITELIST (ntfy_report /
    # manual) or matching FEED_SOURCE_FORMAT (/\Afeed:[a-z0-9_\-]{1,40}\z/) —
    # any other value is rejected with 422 invalid_source. The old
    # "auto_local_spam" was silently rejected on every send. "feed:callscreen_auto"
    # is a valid feed id and keeps this automatic contribution distinguishable
    # from a manual operator "ntfy_report" tap.
    result = RailsdavSpamReporter.report(
      call.from_number,
      source:   "feed:callscreen_auto",
      username: call.tenant&.railsdav_username,
      notes:    call.spam_evidence_note # the AI's WHY enriches the shared DB
    )
    return if result[:ok]
    Rails.logger.warn("ReportSpamGloballyJob: railsdav report failed for call #{call_id}: #{result[:error]}")
  end
end
