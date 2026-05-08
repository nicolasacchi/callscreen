require "test_helper"

class NtfyActionTokenTest < ActiveSupport::TestCase
  test "round-trip: encode then decode returns the bound payload" do
    tok = NtfyActionToken.encode(call_id: 42, action: "whitelist")
    payload = NtfyActionToken.decode(tok)
    assert_equal 42, payload[:call_id]
    assert_equal "whitelist", payload[:action]
  end

  test "decode returns empty hash on a tampered token" do
    tok = NtfyActionToken.encode(call_id: 42, action: "whitelist")
    bad = tok[0..-2] + (tok[-1] == "a" ? "b" : "a")
    assert_equal({}, NtfyActionToken.decode(bad))
  end

  test "decode returns empty hash on blank input" do
    assert_equal({}, NtfyActionToken.decode(nil))
    assert_equal({}, NtfyActionToken.decode(""))
  end

  test "expires after EXPIRES_IN" do
    tok = nil
    travel_to(Time.current) do
      tok = NtfyActionToken.encode(call_id: 1, action: "mark_spam")
    end
    travel_to(NtfyActionToken::EXPIRES_IN.from_now + 1.day) do
      assert_equal({}, NtfyActionToken.decode(tok))
    end
  end

  test "tokens for different actions don't collide" do
    a = NtfyActionToken.encode(call_id: 7, action: "whitelist")
    b = NtfyActionToken.encode(call_id: 7, action: "mark_spam")
    refute_equal a, b
    assert_equal "whitelist", NtfyActionToken.decode(a)[:action]
    assert_equal "mark_spam", NtfyActionToken.decode(b)[:action]
  end
end
