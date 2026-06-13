# frozen_string_literal: true

require_relative "e2e_helper"

class NtfyActionTest < E2ETest
  def test_whitelist_action_marks_contact_and_audits
    # Fire a synthetic call to create the Call row. Skip the recording
    # leg so ScreeningJob doesn't try (and fail) to download — we just
    # need the Call to exist so we can mint a token for it.
    result = fire_call(from: E2E_CALLER_NTFY,
                       scenario: %i[initiated answered playback_ended hangup])
    assert_nil result.error
    call = read_call(result.call_control_id)
    call_id = call["id"]
    assert call_id.is_a?(Integer)

    # Mint an action token via runner; the verifier secret derives from
    # secret_key_base which we can only access in-container.
    tok = docker_runner(<<~RUBY).strip
      puts NtfyActionToken.encode(call_id: #{call_id}, action: "whitelist")
    RUBY

    # POST the action.
    uri = URI("#{TARGET}/ntfy/calls/#{call_id}/whitelist?t=#{URI.encode_www_form_component(tok)}")
    res = Net::HTTP.post(uri, "")
    assert_equal "200", res.code, "expected 200 from ntfy whitelist endpoint"

    # Contact must now be whitelisted.
    contact = read_contact(E2E_CALLER_NTFY)
    refute_nil contact
    assert_equal true, contact["whitelisted"]

    # AuditLog must record source=ntfy.
    audit = JSON.parse(docker_runner(<<~RUBY))
      log = AuditLog.where(action: "whitelist_number")
                    .order(created_at: :desc)
                    .where("metadata LIKE ?", '%"source":"ntfy"%')
                    .first
      puts log ? log.metadata.to_json : "null"
    RUBY
    refute_nil audit
    assert_equal "ntfy", audit["source"]
  end
end
