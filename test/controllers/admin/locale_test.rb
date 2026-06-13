require "test_helper"

# P2-4: the admin console renders in the tenant's chosen language.
module Admin
  class LocaleTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:other)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
    end

    def login
      post tenant_session_url, params: { tenant: { email: @tenant.email, password: "test-password-1234" } }
    end

    test "Italian locale renders Italian navigation + html lang" do
      @tenant.update!(admin_locale: "it")
      login
      get admin_root_url
      assert_response :success
      assert_match "Cruscotto", @response.body         # localized nav label
      assert_match 'lang="it"', @response.body
    end

    test "English locale renders English navigation + html lang" do
      @tenant.update!(admin_locale: "en")
      login
      get admin_root_url
      assert_response :success
      assert_match ">Dashboard<", @response.body
      assert_match 'lang="en"', @response.body
    end
  end
end
