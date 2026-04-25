require "openssl"
require "base64"

# Verifies Telnyx webhook requests using Ed25519 signatures.
# https://developers.telnyx.com/docs/api/v2/programmable-voice/Webhook-Authentication
#
# Telnyx posts two headers with every webhook:
#   Telnyx-Signature-Ed25519: base64 signature of "<timestamp>|<raw body>"
#   Telnyx-Timestamp:         unix epoch seconds
#
# The public key (32-byte raw, base64-encoded in ENV["TELNYX_PUBLIC_KEY"])
# is wrapped into a SubjectPublicKeyInfo DER and verified with OpenSSL.
class TelnyxSignatureVerifier
  # SubjectPublicKeyInfo DER prefix for an Ed25519 public key (RFC 8410).
  ED25519_DER_PREFIX = [ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 ].pack("C*").b
  MAX_TIMESTAMP_DRIFT = 5.minutes

  def initialize(public_key_b64: ENV["TELNYX_PUBLIC_KEY"], clock: Time.method(:now))
    @public_key_b64 = public_key_b64.to_s
    @clock = clock
  end

  def verify(payload:, signature:, timestamp:)
    return false if @public_key_b64.empty?
    return false if signature.to_s.empty? || timestamp.to_s.empty? || payload.nil?
    return false unless within_drift?(timestamp)

    public_key = build_public_key
    signature_bytes = Base64.decode64(signature)
    signing_input = "#{timestamp}|#{payload}"
    public_key.verify(nil, signature_bytes, signing_input)
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    false
  end

  private

  def within_drift?(timestamp)
    ts = Integer(timestamp.to_s, exception: false)
    return false unless ts
    (@clock.call.to_i - ts).abs <= MAX_TIMESTAMP_DRIFT.to_i
  end

  def build_public_key
    raw = Base64.decode64(@public_key_b64)
    raise OpenSSL::PKey::PKeyError, "Expected 32-byte Ed25519 key" unless raw.bytesize == 32
    der = ED25519_DER_PREFIX + raw.b
    OpenSSL::PKey.read(der)
  end
end
