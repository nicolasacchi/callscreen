require "test_helper"

# Cross-controller proof that a non-super-admin tenant only sees its own
# data, regardless of which admin page they hit. The default tenant is
# super-admin so we use the `other` tenant for these checks.
module Admin
  class ScopingTest < ActionDispatch::IntegrationTest
    setup do
      @other = tenants(:other)
      @other.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @other.email, password: "test-password-1234" }
      }
    end

    test "calls index excludes other tenants' calls" do
      foreign_call = tenants(:default).calls.create!(call_sid: "scope-foreign-1", from_number: "+390000000001", status: :completed)
      own_call     = @other.calls.create!(call_sid: "scope-own-1",     from_number: "+390000000002", status: :completed)
      get admin_calls_url
      assert_response :success
      assert_match own_call.from_number,     @response.body
      assert_no_match foreign_call.from_number, @response.body
    end

    test "calls show 404s on a foreign call" do
      foreign_call = tenants(:default).calls.create!(call_sid: "scope-foreign-2", from_number: "+390000000003", status: :completed)
      get admin_call_url(foreign_call)
      assert_response :not_found
    end

    test "contacts index excludes other tenants' contacts" do
      foreign_phone = "+395550000111"
      tenants(:default).contacts.create!(phone: foreign_phone)
      get admin_contacts_url
      assert_response :success
      assert_no_match foreign_phone, @response.body
    end

    test "rules index excludes other tenants' rules" do
      tenants(:default).rules.create!(rule_type: :prefix, action: :block, value: "+9999999", description: "default-only")
      @other.rules.create!(rule_type: :prefix, action: :block, value: "+8888888", description: "mine")
      get admin_rules_url
      assert_response :success
      assert_match "mine", @response.body
      assert_no_match "default-only", @response.body
    end

    test "non-super-admin cannot reach Tenants index" do
      get admin_tenants_url
      assert_response :forbidden
    end

    test "non-super-admin cannot reach global Settings" do
      get admin_settings_url
      assert_response :forbidden
    end

    test "non-super-admin can edit their own profile" do
      get edit_admin_profile_url
      assert_response :success
    end

    test "profile update changes only own row" do
      patch admin_profile_url, params: { tenant: { name: "New Name" } }
      assert_redirected_to admin_profile_path
      assert_equal "New Name", @other.reload.name
      assert_not_equal "New Name", tenants(:default).reload.name
    end
  end
end
