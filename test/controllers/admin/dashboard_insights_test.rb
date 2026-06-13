require "test_helper"

module Admin
  class DashboardInsightsTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: { tenant: { email: @tenant.email, password: "test-password-1234" } }
    end

    test "dashboard renders the screening insights panel (P2-6)" do
      @tenant.calls.create!(call_sid: "ins-1", from_number: "+390000000001", status: :spam)
      get admin_root_url
      assert_response :success
      assert_match "Screening insights", @response.body
    end
  end
end
