require "test_helper"

module Admin
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:other)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
    end

    test "show renders the current tenant's profile" do
      get admin_profile_url
      assert_response :success
      assert_match @tenant.display_name, @response.body
    end

    test "edit renders the form" do
      get edit_admin_profile_url
      assert_response :success
      assert_match(/<form/, @response.body)
    end

    test "update mutates the current tenant" do
      patch admin_profile_url, params: {
        tenant: {
          name: "Updated Name",
          spam_sensitivity: "0.7",
          ntfy_url: "https://ntfy.test/x",
          greeting_variant: "warm"
        }
      }
      assert_redirected_to admin_profile_path
      @tenant.reload
      assert_equal "Updated Name", @tenant.name
      assert_in_delta 0.7, @tenant.spam_sensitivity, 0.001
      assert_equal "https://ntfy.test/x", @tenant.ntfy_url
      assert_equal "warm", @tenant.greeting_variant
    end

    test "update rejects an invalid mobile_number" do
      patch admin_profile_url, params: {
        tenant: { mobile_number: "not-a-number" }
      }
      assert_response :unprocessable_content
    end

    test "update cannot mass-assign :admin or :slug or :email" do
      original_admin = @tenant.admin
      patch admin_profile_url, params: {
        tenant: {
          admin: true,
          slug: "hijacked",
          email: "hijacked@example.test"
        }
      }
      @tenant.reload
      assert_equal original_admin, @tenant.admin, "self-edit must not change admin flag"
      assert_not_equal "hijacked", @tenant.slug
      assert_not_equal "hijacked@example.test", @tenant.email
    end

    test "update of a different tenant's data is impossible (no tenant_id route)" do
      other = tenants(:default)
      patch admin_profile_url, params: { tenant: { name: "Took Over" } }
      assert_redirected_to admin_profile_path
      assert_not_equal "Took Over", other.reload.name
      assert_equal "Took Over", @tenant.reload.name
    end
  end
end
