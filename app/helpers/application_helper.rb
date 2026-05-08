module ApplicationHelper
  # Wraps a phone number in a `tel:` link so tapping it on a phone opens
  # the dialer. Falls back to plain text when the number is blank or
  # doesn't look E.164-ish (so we never produce broken dial intents).
  def phone_link(number, fallback: nil, **options)
    str = number.to_s
    return (fallback || "—") if str.blank?
    digits = str.tr_s(" -()", "").delete(" ")
    return str unless digits.match?(/\A\+?[0-9]{6,15}\z/)
    link_to str, "tel:#{digits}", options
  end
end
