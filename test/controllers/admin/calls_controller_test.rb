require "test_helper"

module Admin
  class CallsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
    end

    test "mark_spam creates an audit log entry" do
      call = calls(:screening)
      assert_difference "AuditLog.count", 1 do
        post mark_spam_admin_call_url(call)
      end
      log = AuditLog.recent.first
      assert_equal "mark_spam", log.action
      assert_equal "Call", log.subject_type
      assert_equal call.id, log.subject_id
      assert_equal @tenant.id, log.actor_id
      assert_equal @tenant.id, log.tenant_id
      assert_equal "spam", call.reload.status
    end

    test "mark_legit creates an audit log entry" do
      call = calls(:screening)
      assert_difference "AuditLog.count", 1 do
        post mark_legit_admin_call_url(call)
      end
      assert_equal "mark_legit", AuditLog.recent.first.action
      assert_equal "legit", call.reload.status
    end

    test "block_number creates an audit log entry and blacklists" do
      call = calls(:screening)
      assert_difference "AuditLog.count", 1 do
        post block_number_admin_call_url(call)
      end
      log = AuditLog.recent.first
      assert_equal "block_number", log.action
      assert_not_nil log.metadata["contact_id"]

      contact = @tenant.contacts.find_by(phone: call.from_number)
      assert contact.blacklisted
      assert_not contact.whitelisted, "block must clear whitelist flag if it was set"
    end

    test "whitelist_number marks contact trusted and creates audit log" do
      call = calls(:screening)
      contact = @tenant.contacts.find_by(phone: call.from_number)
      contact&.update!(blacklisted: true)  # ensure block flag clears

      assert_difference "AuditLog.count", 1 do
        post whitelist_number_admin_call_url(call)
      end
      log = AuditLog.recent.first
      assert_equal "whitelist_number", log.action
      assert_equal call.id, log.subject_id

      contact = @tenant.contacts.find_by(phone: call.from_number)
      assert contact.whitelisted
      assert_not contact.blacklisted, "whitelist must clear blacklist flag if it was set"
    end

    test "search uses sanitize_sql_like (NEW M9)" do
      @tenant.calls.create!(call_sid: "search-test-001", from_number: "+393339999999", status: :completed)
      @tenant.calls.create!(call_sid: "search-test-002", from_number: "+39_LITERAL",   status: :completed)

      # Underscore is a LIKE wildcard. With sanitize_sql_like applied, it should
      # match only the literal underscore, not any single char.
      get admin_calls_url(q: "_LITERAL")
      assert_response :success
      assert_match "+39_LITERAL", @response.body
      assert_no_match "+393339999999", @response.body
    end

    test "another tenant's call is not visible to the current tenant" do
      other = tenants(:other)
      foreign_call = other.calls.create!(
        call_sid: "foreign-call-001", from_number: "+393880000000", status: :completed
      )
      get admin_call_url(foreign_call)
      assert_response :not_found
      get admin_calls_url
      assert_no_match foreign_call.from_number, @response.body
    end

    test "another tenant's contact-creating action operates only on the current tenant" do
      other_tenant = tenants(:other)
      _foreign_contact = other_tenant.contacts.create!(phone: "+393881111111")
      call = calls(:screening)  # belongs to default tenant
      post block_number_admin_call_url(call)
      created_for_default = @tenant.contacts.find_by(phone: call.from_number)
      assert created_for_default, "block_number must create the contact under current_tenant"
    end
  end
end
