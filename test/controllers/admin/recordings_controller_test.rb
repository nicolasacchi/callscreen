require "test_helper"

module Admin
  class RecordingsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
    end

    test "redirects to login when unauthenticated" do
      delete destroy_tenant_session_url
      get admin_recordings_url
      assert_redirected_to "/admin/login"
    end

    test "lists calls with a recording_local_path" do
      call = calls(:legit_completed)
      call.update!(recording_local_path: "/tmp/x.wav")
      get admin_recordings_url
      assert_response :success
      assert_match call.from_number, @response.body
    end

    test "lists calls with only recording_url (no local file yet)" do
      call = calls(:legit_completed)
      call.update!(recording_local_path: nil, recording_url: "https://api.telnyx.com/v2/recordings/abc.wav")
      get admin_recordings_url
      assert_response :success
      assert_match call.from_number, @response.body
      assert_match "Streamed from Telnyx on first play", @response.body
    end

    test "excludes calls without any recording" do
      calls(:legit_completed).update!(recording_local_path: nil, recording_url: nil)
      calls(:spam_completed).update!(recording_local_path: nil, recording_url: nil)
      calls(:screening).update!(recording_local_path: nil, recording_url: nil)
      get admin_recordings_url
      assert_response :success
      assert_match "No recordings yet", @response.body
    end

    test "non-super-admin tenant only sees their own recordings" do
      delete destroy_tenant_session_url
      other = tenants(:other)
      other.update!(password: "test-password-1234", password_confirmation: "test-password-1234", admin: false)
      post tenant_session_url, params: {
        tenant: { email: other.email, password: "test-password-1234" }
      }

      # legit_completed belongs to default tenant, not 'other'
      calls(:legit_completed).update!(recording_local_path: "/tmp/x.wav")
      get admin_recordings_url
      assert_response :success
      assert_no_match calls(:legit_completed).from_number, @response.body
    end
  end
end
