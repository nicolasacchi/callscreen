require "test_helper"

# SEC-1: the super-admin "Active" toggle must actually gate access. A
# deactivated tenant retains their session-less credentials but must be refused
# at authentication, not silently keep full access to their caller PII.
module Admin
  class DeactivatedTenantTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:other)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
    end

    test "a deactivated tenant cannot log in or reach the admin" do
      @tenant.update_columns(active: false)

      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
      get admin_root_url
      assert_redirected_to new_tenant_session_path
    end

    test "an active tenant can log in and reach the admin" do
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
      get admin_root_url
      assert_response :success
    end
  end
end
