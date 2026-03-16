class NtfyNotifier
  def self.notify(title:, message:, priority: nil, tags: [])
    url = ENV["NTFY_URL"]
    return unless url.present?

    HTTParty.post(url,
      headers: {
        "Title" => title.to_s.truncate(100),
        "Priority" => priority || ENV.fetch("NTFY_PRIORITY", "default"),
        "Tags" => Array(tags).join(",")
      },
      body: message.to_s,
      timeout: 10
    )
  rescue => e
    Rails.logger.error("NtfyNotifier error: #{e.class}: #{e.message}")
  end
end
