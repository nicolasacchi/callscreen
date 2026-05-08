# Signs short-lived tokens that authorize a one-shot mutation triggered
# from an ntfy notification button (Whitelist / Mark spam / Mark legit).
# The token binds the call_id and action together; tampering with either
# part of the URL breaks the signature.
class NtfyActionToken
  PURPOSE    = "ntfy_action".freeze
  EXPIRES_IN = 14.days

  def self.encode(call_id:, action:)
    verifier.generate(
      { call_id: call_id, action: action.to_s },
      expires_in: EXPIRES_IN,
      purpose:    PURPOSE
    )
  end

  def self.decode(token)
    return {} if token.blank?
    payload = verifier.verified(token.to_s, purpose: PURPOSE)
    payload.is_a?(Hash) ? payload.symbolize_keys : {}
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    {}
  end

  def self.verifier
    Rails.application.message_verifier(:ntfy_actions)
  end
end
