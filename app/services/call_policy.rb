# Pure accept/block decision for an inbound call — the priority ladder that was
# inlined in TelnyxController#handle_initiated (ARCH-3). It reads
# contact/tenant/external and returns a Decision; it has NO side effects. The
# controller applies the decision (spam response / forward / answer) and bumps a
# matched rule's hit_count. Independently unit-testable (call_policy_test.rb).
class CallPolicy
  # Per-caller burst window. NB: tenant.max_calls_per_caller_per_day is a
  # historical misnomer — the cap is enforced over this short window, not 24h.
  RATE_LIMIT_WINDOW = 15.minutes

  Decision = Struct.new(:disposition, :reason, :source, :force_silent, :notify, :rule, keyword_init: true) do
    def spam?   = disposition == :spam
    def allow?  = disposition == :allow
    def answer? = disposition == :answer
  end

  def self.decide(contact:, tenant:, external:, from:)
    new(contact: contact, tenant: tenant, external: external, from: from).decide
  end

  def initialize(contact:, tenant:, external:, from:)
    @contact  = contact
    @tenant   = tenant
    @external = external
    @from     = from
  end

  def decide
    # 0. Per-caller rate limit. Whitelisted + railsdav-allowed callers are
    # exempt. Always silent regardless of spam_response_mode — engaging a
    # caller who hammers us would self-DoS our Telnyx bill.
    if rate_limited?
      limit = @tenant.max_calls_per_caller_per_day || 10
      return spam("Rate limited (more than #{limit} calls in 15 min)", "rate_limit", force_silent: true)
    end

    # 1. Railsdav centralized-contacts policy.
    if @external.matched?
      case @external.policy
      when "block" then return spam("Railsdav policy: block (#{@external.addressbook})", "railsdav")
      when "allow" then return allow
      end
    end

    # 2. Local blacklist (operator override) — silent, and no push (the
    # operator doesn't want a notification every time a blocked number dials).
    return spam("Contact blacklisted by operator", "blacklist", notify: false) if @contact.blacklisted?

    # 3. Local whitelist (operator override).
    return allow if @contact.whitelisted?

    # 3.5. Cross-tenant global spam DB, placed AFTER railsdav-allow and local
    # whitelist so operator-curated allowlists win.
    return spam(spam_global_reason, "spam_db_global") if @external.spam_global?

    # 4. Per-tenant rules (prefix/regex). action_block is always silent.
    if (rule = matching_rule)
      return spam("Tenant rule blocked", "rule", force_silent: true, rule: rule) if rule.action_block?
      return allow(rule: rule) if rule.action_allow?
    end

    # 5. Default — answer and screen.
    Decision.new(disposition: :answer)
  end

  private

  def spam(reason, source, force_silent: false, notify: true, rule: nil)
    Decision.new(disposition: :spam, reason: reason, source: source,
                 force_silent: force_silent, notify: notify, rule: rule)
  end

  def allow(rule: nil)
    Decision.new(disposition: :allow, rule: rule)
  end

  def rate_limited?
    return false if @contact.whitelisted?
    return false if @external.matched? && @external.policy == "allow"
    limit = (@tenant.max_calls_per_caller_per_day || 10).to_i
    return false if limit <= 0
    @contact.recent_calls_count(within: RATE_LIMIT_WINDOW) > limit
  end

  def matching_rule
    @tenant.rules.active.find { |r| r.matches_number?(@from) }
  end

  def spam_global_reason
    meta  = @external.spam_metadata || {}
    src   = meta["source"].to_s.presence
    count = meta["report_count"].to_i
    parts = [ "Global spam DB hit" ]
    parts << "source: #{src}" if src
    parts << "reports: #{count}" if count > 0
    parts.join(" — ")
  end
end
