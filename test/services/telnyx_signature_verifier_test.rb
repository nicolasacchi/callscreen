require "test_helper"
require "openssl"
require "base64"

class TelnyxSignatureVerifierTest < ActiveSupport::TestCase
  setup do
    # Generate an ephemeral Ed25519 keypair for the test
    @private_key = OpenSSL::PKey.generate_key("ED25519")
    raw_pub = @private_key.raw_public_key
    @public_key_b64 = Base64.strict_encode64(raw_pub)
    @timestamp = Time.now.to_i.to_s
    @payload = '{"data": {"event_type": "call.initiated"}}'
    @verifier = TelnyxSignatureVerifier.new(public_key_b64: @public_key_b64)
  end

  test "accepts valid signature" do
    sig = sign(@payload, @timestamp)
    assert @verifier.verify(payload: @payload, signature: sig, timestamp: @timestamp)
  end

  test "rejects tampered payload" do
    sig = sign(@payload, @timestamp)
    assert_not @verifier.verify(payload: "different payload", signature: sig, timestamp: @timestamp)
  end

  test "rejects wrong signature bytes" do
    bogus = Base64.strict_encode64("\x00" * 64)
    assert_not @verifier.verify(payload: @payload, signature: bogus, timestamp: @timestamp)
  end

  test "rejects expired timestamp (drift > 5 minutes)" do
    old_timestamp = (Time.now.to_i - 6 * 60).to_s
    sig = sign(@payload, old_timestamp)
    assert_not @verifier.verify(payload: @payload, signature: sig, timestamp: old_timestamp)
  end

  test "rejects future timestamp (drift > 5 minutes)" do
    future = (Time.now.to_i + 6 * 60).to_s
    sig = sign(@payload, future)
    assert_not @verifier.verify(payload: @payload, signature: sig, timestamp: future)
  end

  test "rejects when timestamp is missing or non-numeric" do
    sig = sign(@payload, @timestamp)
    assert_not @verifier.verify(payload: @payload, signature: sig, timestamp: "")
    assert_not @verifier.verify(payload: @payload, signature: sig, timestamp: "abc")
  end

  test "rejects when public key is missing" do
    no_key = TelnyxSignatureVerifier.new(public_key_b64: "")
    sig = sign(@payload, @timestamp)
    assert_not no_key.verify(payload: @payload, signature: sig, timestamp: @timestamp)
  end

  test "rejects when signature header is empty" do
    assert_not @verifier.verify(payload: @payload, signature: "", timestamp: @timestamp)
  end

  test "rejects malformed public key" do
    bad = TelnyxSignatureVerifier.new(public_key_b64: Base64.strict_encode64("too short"))
    sig = sign(@payload, @timestamp)
    assert_not bad.verify(payload: @payload, signature: sig, timestamp: @timestamp)
  end

  private

  def sign(payload, timestamp)
    signing_input = "#{timestamp}|#{payload}"
    Base64.strict_encode64(@private_key.sign(nil, signing_input))
  end
end
