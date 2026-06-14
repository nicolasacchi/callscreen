class NtfyNotifier
  WARN_THRESHOLD = 3

  # Raised by `notify` callers (NotifyJob) that want a failed push to be retried
  # rather than silently lost. `notify` itself never raises — it returns a
  # boolean — so callers opt into retry by inspecting the return value.
  class DeliveryError < StandardError; end

  @consecutive_failures = 0
  @mutex = Mutex.new

  class << self
    attr_accessor :consecutive_failures

    def reset_failure_count!
      @mutex.synchronize { @consecutive_failures = 0 }
    end

    # Per-tenant push: caller can pass `url:` and `tenant_priority:` to override
    # the global ENV defaults. Both fall back to ENV when blank so single-tenant
    # installs keep working unchanged. When `call:` is passed, three action
    # buttons are added (Whitelist / Mark spam / Report globally).
    #
    # Returns true when the push was delivered (HTTP 2xx) OR intentionally
    # suppressed (blank destination / "disabled" sentinel) — i.e. "nothing more
    # to do". Returns false when a send was attempted but FAILED (non-2xx
    # response or a raised transport error), so callers can release a notified_at
    # claim and retry instead of treating a dropped push as success.
    #
    # `tenant_priority` (the operator's configured per-tenant priority) WINS over
    # the per-call `priority` when it is an explicit NON-default choice (max/high/
    # low/min) — an operator who picks one expects it to take effect. The column
    # defaults to "default", which means "no override, keep the per-call urgency"
    # (spam=low, legit=high) rather than flattening every push to priority 3.
    def notify(title:, message:, priority: nil, tags: [], url: nil, tenant_priority: nil, call: nil)
      # Explicit per-tenant opt-out: a tenant whose ntfy_url is "disabled" never
      # sends, even though the ENV fallback would otherwise kick in. Used by the
      # e2e tenant so test runs don't push to the operator's real phone.
      return true if url.to_s.strip == "disabled"
      destination = (url.presence || ENV["NTFY_URL"]).to_s.strip
      return true unless destination.present?

      headers = {
        # Title rides in an HTTP header; strip CR/LF/control chars so a caller
        # name containing a newline can't truncate the request or inject headers
        # (Net::HTTP raises on bare CR/LF, which `notify` would otherwise swallow
        # as a lost push). Emoji/UTF-8 are intentionally preserved.
        "Title" => sanitize_header(title).truncate(100),
        "Priority" => effective_priority(tenant_priority, priority),
        "Tags" => Array(tags).join(","),
        "X-Request-ID" => Current.request_id.to_s
      }
      actions = build_actions(call)
      headers["Actions"] = actions if actions.present?

      response = HTTParty.post(destination, headers: headers, body: message.to_s, timeout: 10)

      # HTTParty/Net::HTTP do NOT raise on 4xx/5xx — they return a response. A
      # rejecting-but-reachable ntfy server (wrong topic 404, auth 401/403,
      # rate-limit 429, transient 503) must count as a failure, not a silent
      # success that resets the counter. Mirrors RailsdavSpamReporter.
      if response.success?
        @mutex.synchronize { @consecutive_failures = 0 }
        true
      else
        record_failure!("ntfy HTTP #{response.code}: #{response.body.to_s.first(300)}")
        false
      end
    rescue => e
      record_failure!("#{e.class}: #{e.message}", exception: e)
      false
    end

    private

    # Replace CR/LF/NUL and other control chars with a space; UTF-8 (emoji,
    # accented letters) is preserved.
    def sanitize_header(value)
      value.to_s.gsub(/[[:cntrl:]]/, " ")
    end

    # The per-tenant ntfy_priority column defaults to "default"; treat that (and
    # blank) as "no override" so the per-call urgency stands. Only an explicit
    # non-default operator choice overrides it.
    def effective_priority(tenant_priority, per_call)
      override = tenant_priority.to_s.strip
      override = nil if override.empty? || override == "default"
      override || per_call.presence || ENV.fetch("NTFY_PRIORITY", "default")
    end

    def record_failure!(detail, exception: nil)
      Rails.logger.error("NtfyNotifier error: #{detail}")
      failures = @mutex.synchronize { @consecutive_failures += 1 }
      if failures >= WARN_THRESHOLD
        Rails.logger.warn("NtfyNotifier has failed #{failures} consecutive times")
      end
      # Surface to Sentry like every sibling in the notification path — otherwise
      # an ntfy outage/misconfig is invisible until the operator notices missing
      # pushes. Guarded: Sentry is a no-op when uninitialised (no DSN).
      if defined?(Sentry)
        exception ? Sentry.capture_exception(exception) : Sentry.capture_message("NtfyNotifier delivery failed: #{detail}")
      end
    end

    def build_actions(call)
      return nil unless call && call.id && call.from_number.present?
      base = ENV.fetch("APP_DOMAIN", "https://phone.example.com")
      tok_w = NtfyActionToken.encode(call_id: call.id, action: "whitelist")
      tok_s = NtfyActionToken.encode(call_id: call.id, action: "mark_spam")
      tok_g = NtfyActionToken.encode(call_id: call.id, action: "report_spam_globally")
      [
        "http, Whitelist, #{base}/ntfy/calls/#{call.id}/whitelist?t=#{tok_w}, method=POST, clear=true",
        "http, Mark spam, #{base}/ntfy/calls/#{call.id}/spam?t=#{tok_s}, method=POST, clear=true",
        "http, Report globally, #{base}/ntfy/calls/#{call.id}/report_spam_globally?t=#{tok_g}, method=POST, clear=true"
      ].join("; ")
    end
  end
end
