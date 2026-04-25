Rack::Attack.throttle("telnyx/ip", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/telnyx/")
end

# Throttle admin login by IP
Rack::Attack.throttle("admin/login/ip", limit: 10, period: 5.minutes) do |req|
  req.ip if req.path == "/admin/login" && req.post?
end

# Throttle admin login by submitted email (slows credential stuffing across IPs)
Rack::Attack.throttle("admin/login/email", limit: 5, period: 20.minutes) do |req|
  if req.path == "/admin/login" && req.post?
    email = req.params.dig("admin_user", "email").to_s.downcase.strip.presence
    email
  end
end
