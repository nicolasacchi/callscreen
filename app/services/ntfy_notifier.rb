class NtfyNotifier
  WARN_THRESHOLD = 3

  @consecutive_failures = 0
  @mutex = Mutex.new

  class << self
    attr_accessor :consecutive_failures

    def reset_failure_count!
      @mutex.synchronize { @consecutive_failures = 0 }
    end

    # Per-tenant push: caller can pass `url:` and `default_priority:` to
    # override the global ENV defaults. Both fall back to ENV when blank
    # so single-tenant installs keep working unchanged.
    # When `call:` is passed, three notification action buttons are added
    # (Whitelist / Mark spam / Call back).
    def notify(title:, message:, priority: nil, tags: [], url: nil, default_priority: nil, call: nil)
      # Explicit per-tenant opt-out: a tenant whose ntfy_url is set to the
      # literal string "disabled" never sends, even though the ENV
      # fallback would otherwise kick in. Used by the e2e tenant so test
      # runs don't push real notifications to the operator's phone.
      return if url.to_s == "disabled"
      destination = url.presence || ENV["NTFY_URL"]
      return unless destination.present?

      headers = {
        "Title" => title.to_s.truncate(100),
        "Priority" => priority || default_priority || ENV.fetch("NTFY_PRIORITY", "default"),
        "Tags" => Array(tags).join(","),
        "X-Request-ID" => Current.request_id.to_s
      }
      actions = build_actions(call)
      headers["Actions"] = actions if actions.present?

      HTTParty.post(destination,
        headers: headers,
        body: message.to_s,
        timeout: 10
      )
      @mutex.synchronize { @consecutive_failures = 0 }
    rescue => e
      Rails.logger.error("NtfyNotifier error: #{e.class}: #{e.message}")
      failures = @mutex.synchronize { @consecutive_failures += 1 }
      if failures >= WARN_THRESHOLD
        Rails.logger.warn("NtfyNotifier has failed #{failures} consecutive times")
      end
    end

    private

    def build_actions(call)
      return nil unless call && call.id && call.from_number.present?
      base = ENV.fetch("APP_DOMAIN", "https://phone.example.com")
      tok_w = NtfyActionToken.encode(call_id: call.id, action: "whitelist")
      tok_s = NtfyActionToken.encode(call_id: call.id, action: "mark_spam")
      [
        "http, Whitelist, #{base}/ntfy/calls/#{call.id}/whitelist?t=#{tok_w}, method=POST, clear=true",
        "http, Mark spam, #{base}/ntfy/calls/#{call.id}/spam?t=#{tok_s}, method=POST, clear=true",
        "view, Call back, tel:#{call.from_number}, clear=true"
      ].join("; ")
    end
  end
end
