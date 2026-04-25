class NtfyNotifier
  WARN_THRESHOLD = 3

  @consecutive_failures = 0
  @mutex = Mutex.new

  class << self
    attr_accessor :consecutive_failures

    def reset_failure_count!
      @mutex.synchronize { @consecutive_failures = 0 }
    end

    def notify(title:, message:, priority: nil, tags: [])
      url = ENV["NTFY_URL"]
      return unless url.present?

      HTTParty.post(url,
        headers: {
          "Title" => title.to_s.truncate(100),
          "Priority" => priority || ENV.fetch("NTFY_PRIORITY", "default"),
          "Tags" => Array(tags).join(","),
          "X-Request-ID" => Current.request_id.to_s
        },
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
  end
end
