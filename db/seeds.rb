operator_email = ENV.fetch("ADMIN_EMAIL", "admin@callscreen.local")
operator_password = ENV.fetch("ADMIN_PASSWORD") do
  if Rails.env.production?
    raise "ADMIN_PASSWORD environment variable is required in production"
  end
  "changeme123!"
end

# The single bootstrap tenant is the operator: super-admin + default tenant
# (used for fallback when an inbound call cannot be attributed to any other
# row via dedicated_number or History-Info).
operator_slug = operator_email.split("@").first.downcase.gsub(/[^a-z0-9._-]/, "-")

operator = Tenant.find_or_initialize_by(email: operator_email)
operator.password              ||= operator_password
operator.password_confirmation ||= operator_password
operator.slug                  ||= operator_slug
operator.name                  ||= operator_slug
operator.default_tenant          = true
operator.admin                   = true
operator.active                  = true
operator.save!

Setting::DEFAULTS.each do |key, value|
  Setting.find_or_create_by!(key: key) do |s|
    s.value = value
    s.description = key.humanize
  end
end
