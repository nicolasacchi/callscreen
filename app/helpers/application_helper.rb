module ApplicationHelper
  # Wraps a phone number in a `tel:` link so tapping it on a phone opens
  # the dialer. Falls back to plain text when the number is blank or
  # doesn't look E.164-ish (so we never produce broken dial intents).
  def phone_link(number, fallback: nil, **options)
    str = number.to_s
    return (fallback || "—") if str.blank?
    digits = str.tr_s(" -()", "").delete(" ")
    return str unless digits.match?(Tenant::E164_FORMAT)
    link_to str, "tel:#{digits}", options
  end

  # Per-tenant display timezone for admin views (I18N-2). Uses the tenant being
  # viewed (super-admin cross-tenant pages) when available, else the logged-in
  # tenant; falls back to Europe/Rome. Replaces the hardcoded "Europe/Rome"
  # literal that showed wrong wall-clock times to tenants in other zones.
  # Sidebar nav link that marks the current page for both sighted users (the
  # .active class) and assistive tech (aria-current="page").
  def admin_nav_link(label, path, controller)
    active = controller_path == controller
    link_to label, path, class: ("active" if active), aria: { current: (active ? "page" : nil) }
  end

  def tenant_time_zone
    tz = if respond_to?(:viewing_tenant)
      viewing_tenant&.time_zone
    elsif respond_to?(:current_tenant)
      current_tenant&.time_zone
    end
    tz.presence || "Europe/Rome"
  end
end
