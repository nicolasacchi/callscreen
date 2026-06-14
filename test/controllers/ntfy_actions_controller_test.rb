require "test_helper"

class NtfyActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default)
    @call = @tenant.calls.create!(
      call_sid: "ntfy-action-1", call_control_id: "ntfy-action-1",
      from_number: "+393334445555", status: :spam
    )
  end

  test "whitelist: valid token creates contact + audit log with actor=nil" do
    tok = NtfyActionToken.encode(call_id: @call.id, action: "whitelist")
    assert_difference -> { Contact.count } => 1, -> { AuditLog.count } => 1 do
      post ntfy_whitelist_call_url(@call.id, t: tok)
    end
    assert_response :ok
    contact = Contact.where(tenant: @tenant, phone: @call.from_number).last
    assert contact.whitelisted?
    refute contact.blacklisted?
    log = AuditLog.recent.first
    assert_nil log.actor_id
    assert_equal "whitelist_number", log.action
    assert_equal "ntfy", log.metadata["source"]
  end

  test "whitelist propagates the allow decision UP to railsdav (when configured)" do
    ENV["RAILSDAV_API_URL"] = "http://railsdav.test:3000"
    tok = NtfyActionToken.encode(call_id: @call.id, action: "whitelist")
    assert_enqueued_jobs 1, only: RailsdavAllowJob do
      post ntfy_whitelist_call_url(@call.id, t: tok)
    end
    assert_response :ok
  ensure
    ENV["RAILSDAV_API_URL"] = ""
  end

  test "mark_spam: valid token flips status + creates audit row" do
    @call.update!(status: :legit)
    tok = NtfyActionToken.encode(call_id: @call.id, action: "mark_spam")
    post ntfy_spam_call_url(@call.id, t: tok)
    assert_response :ok
    assert_equal "spam", @call.reload.status
    assert_equal "ntfy", AuditLog.recent.first.metadata["source"]
  end

  test "rejects token issued for a different action" do
    tok = NtfyActionToken.encode(call_id: @call.id, action: "whitelist")
    post ntfy_spam_call_url(@call.id, t: tok)  # tok is for whitelist, URL is spam
    assert_response :unauthorized
  end

  test "rejects token bound to a different call_id" do
    other = @tenant.calls.create!(
      call_sid: "ntfy-other-1", call_control_id: "ntfy-other-1",
      from_number: "+393331111111", status: :spam
    )
    tok = NtfyActionToken.encode(call_id: other.id, action: "whitelist")
    post ntfy_whitelist_call_url(@call.id, t: tok)  # tok is for `other`, URL says @call
    assert_response :unauthorized
  end

  test "rejects missing or tampered token" do
    post ntfy_spam_call_url(@call.id, t: "garbage")
    assert_response :unauthorized

    post ntfy_spam_call_url(@call.id)
    assert_response :unauthorized
  end

  test "404 when the token's call no longer exists" do
    tok = NtfyActionToken.encode(call_id: 999_999, action: "whitelist")
    post ntfy_whitelist_call_url(999_999, t: tok)
    assert_response :not_found
  end

  test "report_spam_globally: success posts to railsdav, audits, marks call spam" do
    @call.update!(status: :legit)
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "test-token"
    stub_request(:post, "http://railsdav.test:3000/api/spam_reports").to_return(status: 200, body: "{}")

    tok = NtfyActionToken.encode(call_id: @call.id, action: "report_spam_globally")
    post ntfy_report_spam_globally_call_url(@call.id, t: tok)
    assert_response :ok
    assert_equal "spam", @call.reload.status
    log = AuditLog.recent.first
    assert_equal "report_spam_globally", log.action
    assert_equal true, log.metadata["railsdav_ack"]
    assert_equal "ntfy", log.metadata["source"]
  ensure
    ENV.delete("RAILSDAV_API_URL")
    ENV.delete("RAILSDAV_API_TOKEN")
  end

  test "report_spam_globally: railsdav failure surfaces 502 to ntfy" do
    ENV["RAILSDAV_API_URL"]   = "http://railsdav.test:3000"
    ENV["RAILSDAV_API_TOKEN"] = "test-token"
    stub_request(:post, "http://railsdav.test:3000/api/spam_reports").to_return(status: 503, body: "boom")

    tok = NtfyActionToken.encode(call_id: @call.id, action: "report_spam_globally")
    post ntfy_report_spam_globally_call_url(@call.id, t: tok)
    assert_response :bad_gateway
    log = AuditLog.recent.first
    assert_equal "report_spam_globally", log.action
    assert_equal false, log.metadata["railsdav_ack"]
  ensure
    ENV.delete("RAILSDAV_API_URL")
    ENV.delete("RAILSDAV_API_TOKEN")
  end

  test "whitelist mid-troll hangs up the active call leg" do
    @call.update!(flow_state: "troll_playing", status: :spam)
    stub_request(:post, %r{api\.telnyx\.com/v2/calls/.+/actions/hangup}).to_return(status: 200, body: "{}")

    tok = NtfyActionToken.encode(call_id: @call.id, action: "whitelist")
    post ntfy_whitelist_call_url(@call.id, t: tok)
    assert_response :ok
    assert_equal "done", @call.reload.flow_state
    assert_requested :post, %r{api\.telnyx\.com/v2/calls/#{@call.call_control_id}/actions/hangup}
  end

  test "whitelist while not in a spam-playback state does NOT issue a hangup" do
    @call.update!(flow_state: "done", status: :spam)
    tok = NtfyActionToken.encode(call_id: @call.id, action: "whitelist")
    post ntfy_whitelist_call_url(@call.id, t: tok)
    assert_response :ok
    assert_not_requested :post, %r{api\.telnyx\.com/v2/calls/.+/actions/hangup}
  end
end
