# Durable throttle counters in production: the default Rails.cache is a
# per-process memory store, so login-throttle state would reset on every
# deploy and not coordinate across workers. A FileStore on the storage volume
# survives restarts. Test/dev keep the default memory store so throttle tests
# stay deterministic (SEC-3).
if Rails.env.production?
  Rack::Attack.cache.store = ActiveSupport::Cache::FileStore.new(
    Rails.root.join("storage", "rack_attack_cache").to_s
  )
end

Rack::Attack.throttle("telnyx/ip", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/telnyx/")
end

# ntfy action endpoints are authed only by a signed token (no session). Throttle
# by IP so a leaked/forwarded token can't be replayed in a tight loop (SEC-1).
Rack::Attack.throttle("ntfy/ip", limit: 30, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/ntfy/")
end

# Throttle admin login by IP
Rack::Attack.throttle("admin/login/ip", limit: 10, period: 5.minutes) do |req|
  req.ip if req.path == "/admin/login" && req.post?
end

# Throttle admin login by submitted email (slows credential stuffing across IPs)
Rack::Attack.throttle("admin/login/email", limit: 5, period: 20.minutes) do |req|
  if req.path == "/admin/login" && req.post?
    email = req.params.dig("tenant", "email").to_s.downcase.strip.presence
    email
  end
end
