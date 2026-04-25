require "test_helper"

class RecordingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = AdminUser.create!(
      email: "admin@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234"
    )
    sign_in @admin
  end

  test "redirects to login when unauthenticated" do
    sign_out @admin
    call = calls(:legit_completed)
    get recording_url(call)
    assert_redirected_to "/admin/login"
  end

  test "returns 404 when recording_local_path is blank" do
    call = calls(:legit_completed)
    call.update!(recording_local_path: nil)
    get recording_url(call)
    assert_response :not_found
  end

  test "returns 404 when call_sid does not match strict format" do
    call = calls(:legit_completed)
    call.update_columns(call_sid: "../../etc/passwd")  # bypass validation to simulate corrupted DB
    get recording_url(call)
    assert_response :not_found
  end

  test "returns 404 when file does not exist on disk" do
    call = calls(:legit_completed)
    call.update!(recording_local_path: Rails.root.join("storage/recordings/#{call.call_sid}.wav").to_s)
    get recording_url(call)
    assert_response :not_found
  end

  test "serves the recording when path is valid and file exists" do
    call = calls(:legit_completed)
    path = Rails.root.join("storage/recordings/#{call.call_sid}.wav")
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "RIFF dummy wav data")
    call.update!(recording_local_path: path.to_s)

    get recording_url(call)
    assert_response :success
    assert_equal "audio/wav", @response.media_type
  ensure
    FileUtils.rm_f(path) if path
  end

  private

  def sign_in(admin)
    post admin_user_session_url, params: { admin_user: { email: admin.email, password: "test-password-1234" } }
  end

  def sign_out(_admin)
    delete destroy_admin_user_session_url
  end
end
