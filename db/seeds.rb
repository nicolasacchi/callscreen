admin_email = ENV.fetch("ADMIN_EMAIL", "admin@callscreen.local")
admin_password = ENV.fetch("ADMIN_PASSWORD") do
  if Rails.env.production?
    raise "ADMIN_PASSWORD environment variable is required in production"
  end
  "changeme123!"
end

AdminUser.find_or_create_by!(email: admin_email) do |admin|
  admin.password = admin_password
  admin.password_confirmation = admin_password
end

Setting::DEFAULTS.each do |key, value|
  Setting.find_or_create_by!(key: key) do |s|
    s.value = value
    s.description = key.humanize
  end
end
