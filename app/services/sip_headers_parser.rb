# Parses Telnyx Voice API `sip_headers` array entries from inbound webhooks.
# Specifically the History-Info header (RFC 7044) which Italian carriers
# (TIM via Irideos confirmed; others unverified) use to convey the original
# called number on a forwarded call. Sample History-Info header:
#
#   { "name" => "History-Info",
#     "value" => "<sip:+393990000001@telecomitalia.it;user=phone?Privacy=none>;index=1, " \
#                "<sip:+390999000355@telecomitalia.it;user=phone;cause=408>;index=1.1" }
#
# The lowest-indexed URI carries the *original called number* (the user's
# mobile). Subsequent entries are the redirect chain. The cause= parameter
# on the last entry indicates the redirect reason (408 = no-answer,
# 486 = busy, 408 again or 480 = unreachable).
class SipHeadersParser
  HEADER_NAME = "History-Info".freeze
  # Matches the user-part of <sip:USER@host;...>. Conservative: only digits,
  # plus, dot, hyphen, parens, and asterisk (telephone-subscriber chars per
  # RFC 3261). Anything outside that is ignored to avoid pulling in tokens
  # we shouldn't try to dial back.
  URI_USER = /<sips?:([+0-9.\-*()]+)@/

  def self.original_called_number(sip_headers)
    return nil unless sip_headers.is_a?(Array)

    header = sip_headers.find { |h| header_match?(h) }
    return nil unless header

    # The lowest-index entry is the FIRST <sip:…> in the comma-separated list.
    match = header["value"].to_s.match(URI_USER)
    return nil unless match

    PhoneNumberNormalizer.normalize(match[1])
  end

  # The `cause=NNN` parameter (RFC 7044 §6.4) lives on the LAST entry of
  # the History-Info chain — the most recent redirect. Useful for
  # distinguishing no-answer (408) vs busy (486) vs unreachable (480).
  def self.redirect_cause(sip_headers)
    return nil unless sip_headers.is_a?(Array)

    header = sip_headers.find { |h| header_match?(h) }
    return nil unless header

    causes = header["value"].to_s.scan(/cause=(\d+)/).flatten
    return nil if causes.empty?

    causes.last.to_i
  end

  # Returns true if the call was reached via at least one redirect (i.e.
  # History-Info is present and contains more than one URI).
  def self.forwarded?(sip_headers)
    return false unless sip_headers.is_a?(Array)
    header = sip_headers.find { |h| header_match?(h) }
    return false unless header
    header["value"].to_s.scan(URI_USER).size > 1
  end

  def self.header_match?(h)
    return false unless h.is_a?(Hash)
    h["name"].to_s.casecmp?(HEADER_NAME)
  end
end
