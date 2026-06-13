# Pure decision: should this caller be auto-blacklisted after repeated spam?
# Extracted from ScreeningJob#auto_blacklist_if_pattern_match (ARCH-5) — the
# write-side counterpart to CallPolicy. No side effects: returns a Decision the
# job persists (contact update + audit row).
#
# A nil threshold DISABLES auto-blacklist (the validator forbids 0, so nil is the
# only off switch); a set value is >= 1. Already-blacklisted/whitelisted contacts
# and a non-positive window are no-ops.
class AutoBlacklistPolicy
  Decision = Struct.new(:blacklist, :count, :window_days, :threshold, keyword_init: true) do
    def blacklist? = blacklist
  end

  def self.decide(call)
    new(call).decide
  end

  def initialize(call)
    @tenant  = call.tenant
    @contact = call.contact
  end

  def decide
    return none unless @contact
    return none if @contact.blacklisted? || @contact.whitelisted?

    threshold = @tenant.auto_blacklist_threshold
    return none if threshold.nil? || threshold.to_i <= 0

    window = @tenant.auto_blacklist_window_days
    window = window.nil? ? 7 : window.to_i
    return none if window <= 0

    count = @contact.recent_spam_count(within: window.days)
    return none if count < threshold.to_i

    Decision.new(blacklist: true, count: count, window_days: window, threshold: threshold.to_i)
  end

  private

  def none
    Decision.new(blacklist: false)
  end
end
