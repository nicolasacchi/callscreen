Rack::Attack.throttle("telnyx/ip", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/telnyx/")
end
