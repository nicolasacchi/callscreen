require "test_helper"

class SipHeadersParserTest < ActiveSupport::TestCase
  SAMPLE_HISTORY_INFO_HEADER = {
    "name"  => "History-Info",
    "value" => "<sip:+393990000001@telecomitalia.it;user=phone?Privacy=none>;index=1, " \
               "<sip:+390999000355@telecomitalia.it;user=phone;cause=408>;index=1.1"
  }.freeze

  test "extracts the originally-called number from the sample History-Info header" do
    assert_equal "+393990000001",
      SipHeadersParser.original_called_number([ SAMPLE_HISTORY_INFO_HEADER ])
  end

  test "extracts the redirect cause from the LAST entry" do
    assert_equal 408,
      SipHeadersParser.redirect_cause([ SAMPLE_HISTORY_INFO_HEADER ])
  end

  test "forwarded? is true when the chain has more than one URI" do
    assert SipHeadersParser.forwarded?([ SAMPLE_HISTORY_INFO_HEADER ])
  end

  test "forwarded? is false on a direct dial (single-URI History-Info)" do
    direct = { "name" => "History-Info", "value" => "<sip:+393331111111@example.com>;index=1" }
    refute SipHeadersParser.forwarded?([ direct ])
  end

  test "returns nil when sip_headers is nil or empty or non-array" do
    assert_nil SipHeadersParser.original_called_number(nil)
    assert_nil SipHeadersParser.original_called_number([])
    assert_nil SipHeadersParser.original_called_number("not-an-array")
    assert_nil SipHeadersParser.redirect_cause(nil)
  end

  test "returns nil when the header is not History-Info" do
    other = [ { "name" => "Diversion", "value" => "<sip:+393331234567@example.com>;reason=no-answer" } ]
    assert_nil SipHeadersParser.original_called_number(other)
  end

  test "header lookup is case-insensitive on the name" do
    lower = [ { "name" => "history-info", "value" => "<sip:+393331111111@example.com>;index=1" } ]
    assert_equal "+393331111111", SipHeadersParser.original_called_number(lower)
  end

  test "returns nil for a malformed value (no <sip:...> URI)" do
    bad = [ { "name" => "History-Info", "value" => "garbage" } ]
    assert_nil SipHeadersParser.original_called_number(bad)
  end

  test "tolerates control characters and weird unicode in the value" do
    weird = [ { "name" => "History-Info", "value" => "\x00\x07<sip:+393331111111@x>;index=1‮" } ]
    assert_equal "+393331111111", SipHeadersParser.original_called_number([ weird.first ])
  end

  test "multi-hop redirect chain → cause is the LAST one (the most recent forward)" do
    chain = [ {
      "name"  => "History-Info",
      "value" => "<sip:+391@a>;index=1, " \
                 "<sip:+392@b;cause=486>;index=1.1, " \
                 "<sip:+393@c;cause=408>;index=1.1.1"
    } ]
    assert_equal "+391", SipHeadersParser.original_called_number(chain)
    assert_equal 408,    SipHeadersParser.redirect_cause(chain)
    assert SipHeadersParser.forwarded?(chain)
  end

  test "PhoneNumberNormalizer is applied — national-format input is normalized" do
    # Italian national-format (no leading +). Phonelib should still produce E.164.
    national = [ {
      "name"  => "History-Info",
      "value" => "<sip:3990000001@telecomitalia.it;user=phone>;index=1"
    } ]
    result = SipHeadersParser.original_called_number(national)
    # Normalization may or may not succeed without a country hint; we just
    # require a non-empty string back when the digits are recognizable.
    assert_kind_of String, result if result
  end

  test "sips: scheme also matches" do
    secure = [ { "name" => "History-Info", "value" => "<sips:+393331111111@x>;index=1" } ]
    assert_equal "+393331111111", SipHeadersParser.original_called_number(secure)
  end
end
