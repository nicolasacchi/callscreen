class PhoneNumberNormalizer
  # Single source of truth for the default region, matching railsdav (which reads
  # the same ENV in PhoneLookup + SpamNumber.normalize_e164). If an operator ever
  # sets a non-IT country on one service, both MUST agree or the two key the same
  # national number to different E.164 (silent contact misses + wrong spam rows).
  def self.default_country
    ENV.fetch("PHONE_DEFAULT_COUNTRY", "IT")
  end

  # Lenient: E.164 when parseable, else the raw stripped input. Used for display
  # + local contact keying, where keeping *something* beats dropping it.
  def self.normalize(number, default_country: default_country())
    return number if number.blank?

    phone = Phonelib.parse(number, default_country)
    phone.valid? ? phone.e164 : number.strip
  end

  # Strict: E.164 only, or nil when the number isn't a valid phone number
  # (anonymous/withheld/shortcode/alphanumeric SIP From). Use at the railsdav
  # boundary so we never send a value the validator-of-record will reject anyway
  # (lookup → match:false, spam_report → 422 → 502 on the operator's ntfy tap).
  def self.e164(number, default_country: default_country())
    return nil if number.blank?
    phone = Phonelib.parse(number, default_country)
    phone.valid? ? phone.e164 : nil
  end
end
