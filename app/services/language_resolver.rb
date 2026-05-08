# Resolves "it" or "en" for a call. Single source of truth used by both
# TelnyxController and ScreeningJob; replaces the duplicated
# `caller_language` helpers that previously lived in both files.
#
# Precedence:
#   1. contact.language override (if the contact exists and set the field)
#   2. tenant.auto_detect_language ? language_from_e164 : tenant.greeting_language[0..1]
class LanguageResolver
  ALLOWED = %w[it en].freeze

  def self.for(call)
    return "it" if call.nil?

    contact = call.contact
    if contact && ALLOWED.include?(contact.language.to_s)
      return contact.language
    end

    tenant = call.tenant
    if tenant&.auto_detect_language
      from_e164(call.from_number)
    else
      pinned = tenant&.greeting_language.to_s[0, 2].to_s.downcase
      ALLOWED.include?(pinned) ? pinned : "it"
    end
  end

  def self.from_e164(number)
    number.to_s.start_with?("+39") ? "it" : "en"
  end
end
