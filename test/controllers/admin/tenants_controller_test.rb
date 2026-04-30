require "test_helper"

module Admin
  class TenantsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = tenants(:default)
      @admin.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      @other = tenants(:other)
      @other.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      sign_in @admin
    end

    test "index lists all tenants for super-admin" do
      get admin_tenants_url
      assert_response :success
      assert_match @admin.email, @response.body
      assert_match @other.email, @response.body
    end

    test "show renders for any tenant when super-admin" do
      get admin_tenant_url(@other)
      assert_response :success
    end

    test "non-super-admin is forbidden from index" do
      sign_out
      sign_in @other  # other.admin == false
      get admin_tenants_url
      assert_response :forbidden
    end

    test "create requires password and unique slug + valid mobile_number" do
      assert_difference -> { Tenant.count }, 1 do
        post admin_tenants_url, params: {
          tenant: {
            email: "newbie@example.test",
            password: "test-password-1234",
            password_confirmation: "test-password-1234",
            slug: "newbie",
            name: "Newbie",
            mobile_number: "+393881111111",
            railsdav_username: "newbie"
          }
        }
      end
      created = Tenant.find_by!(slug: "newbie")
      assert_redirected_to admin_tenant_path(created)
      refute created.super_admin?
      assert created.active
    end

    test "create rejects when password is missing" do
      assert_no_difference -> { Tenant.count } do
        post admin_tenants_url, params: {
          tenant: { email: "no-password@example.test", slug: "no-pw" }
        }
      end
      assert_response :unprocessable_content
    end

    test "create rejects duplicate mobile_number" do
      assert_no_difference -> { Tenant.count } do
        post admin_tenants_url, params: {
          tenant: {
            email: "dup@example.test",
            password: "test-password-1234",
            password_confirmation: "test-password-1234",
            slug: "dup",
            mobile_number: @admin.mobile_number  # already taken by default tenant
          }
        }
      end
      assert_response :unprocessable_content
    end

    test "update mutates per-tenant settings" do
      patch admin_tenant_url(@other), params: {
        tenant: {
          spam_sensitivity: "0.8",
          forward_back_number: "+393997776665",
          greeting_variant: "warm"
        }
      }
      assert_redirected_to admin_tenant_path(@other)
      @other.reload
      assert_in_delta 0.8, @other.spam_sensitivity, 0.001
      assert_equal "+393997776665", @other.forward_back_number
      assert_equal "warm", @other.greeting_variant
    end

    test "destroy refuses on the default tenant" do
      assert_no_difference -> { Tenant.count } do
        delete admin_tenant_url(@admin)
      end
      assert_redirected_to admin_tenants_path
      assert_match(/Cannot delete the default tenant/, flash[:alert])
    end

    test "destroy refuses when the tenant still owns calls (restrict_with_error)" do
      @other.calls.create!(call_sid: "owned-call", from_number: "+393881111111", status: :completed)
      assert_no_difference -> { Tenant.count } do
        delete admin_tenant_url(@other)
      end
      assert_redirected_to admin_tenants_path
      assert_match(/Cannot delete/, flash[:alert])
    end

    test "destroy succeeds on a fresh tenant with no associations" do
      empty = Tenant.create!(
        email: "empty@example.test",
        password: "test-password-1234",
        password_confirmation: "test-password-1234",
        slug: "empty",
        admin: false, default_tenant: false
      )
      assert_difference -> { Tenant.count }, -1 do
        delete admin_tenant_url(empty)
      end
      assert_redirected_to admin_tenants_path
    end

    private

    def sign_in(tenant)
      post tenant_session_url, params: {
        tenant: { email: tenant.email, password: "test-password-1234" }
      }
    end

    def sign_out
      delete destroy_tenant_session_url
    end
  end
end
