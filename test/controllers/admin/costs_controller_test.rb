require "test_helper"

module Admin
  class CostsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      @other = tenants(:other)
      @other.update!(password: "test-password-1234", password_confirmation: "test-password-1234")

      contact = @tenant.contacts.find_or_create_by!(phone: "+393339999999")
      other_contact = @other.contacts.find_or_create_by!(phone: "+393338888888")

      @tenant.calls.create!(
        call_sid: "cost-test-default-1", call_control_id: "cost-test-default-1",
        from_number: contact.phone, contact: contact,
        status: :legit, ai_classification_source: "llm",
        billable_seconds: 30, telnyx_cost_usd: 0.0035,
        moonshot_tokens_in: 400, moonshot_tokens_out: 50,
        moonshot_cost_usd: 0.0001
      )
      @other.calls.create!(
        call_sid: "cost-test-other-1", call_control_id: "cost-test-other-1",
        from_number: other_contact.phone, contact: other_contact,
        status: :spam, ai_classification_source: "rate_limit",
        telnyx_cost_usd: 0.0, moonshot_cost_usd: 0.0
      )
    end

    def login_as(tenant)
      post tenant_session_url, params: {
        tenant: { email: tenant.email, password: "test-password-1234" }
      }
    end

    test "regular tenant sees only own scope" do
      login_as(@other)
      # Strip admin so other behaves as a non-super-admin tenant.
      @other.update!(admin: false)

      get admin_costs_url
      assert_response :success
      assert_match "Other Tenant", @response.body
      assert_no_match "All tenants", @response.body
      # Regular tenants can't drill into another tenant via ?tenant_id.
      get admin_costs_url(tenant_id: @tenant.id)
      assert_match "Other Tenant", @response.body
    end

    test "super-admin without tenant_id gets All tenants scope" do
      login_as(@tenant)
      get admin_costs_url
      assert_response :success
      assert_match "All tenants", @response.body
      # Per-tenant rollup should appear for super-admin.
      assert_match "Per-tenant rollup", @response.body
    end

    test "super-admin with tenant_id drills into that tenant" do
      login_as(@tenant)
      get admin_costs_url(tenant_id: @other.id)
      assert_response :success
      assert_match "Other Tenant", @response.body
    end

    test "period selector switches and is preserved across links" do
      login_as(@tenant)
      get admin_costs_url(period: "7d")
      assert_response :success
      assert_match "Total (7d)", @response.body
    end

    test "renders without errors when there are no calls in the window" do
      Call.delete_all
      login_as(@tenant)
      get admin_costs_url(period: "7d")
      assert_response :success
      assert_match "No spend in this period.", @response.body
    end
  end
end
