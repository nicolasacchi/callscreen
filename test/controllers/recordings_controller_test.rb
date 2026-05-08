require "test_helper"

class RecordingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default)
    @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
    sign_in_tenant @tenant
  end

  test "redirects to login when unauthenticated" do
    sign_out_tenant
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

  test "fetches from Telnyx when local file is missing but recording_url is set" do
    call = calls(:legit_completed)
    path = Rails.root.join("storage/recordings/#{call.call_sid}.wav")
    FileUtils.rm_f(path)
    call.update!(
      recording_local_path: nil,
      recording_url: "https://s3.amazonaws.com/telephony-recorder/abc.wav"
    )
    stub_request(:get, call.recording_url).to_return(
      status: 200, body: "RIFF stub wav data", headers: { "Content-Type" => "audio/wav" }
    )

    get recording_url(call)

    assert_response :success
    assert_equal "audio/wav", @response.media_type
    assert_path_exists path.to_s
    assert_equal path.to_s, call.reload.recording_local_path
  ensure
    FileUtils.rm_f(path) if path
  end

  test "returns 404 when Telnyx fallback fetch fails" do
    call = calls(:legit_completed)
    path = Rails.root.join("storage/recordings/#{call.call_sid}.wav")
    FileUtils.rm_f(path)
    call.update!(
      recording_local_path: nil,
      recording_url: "https://s3.amazonaws.com/telephony-recorder/missing.wav"
    )
    stub_request(:get, call.recording_url).to_return(status: 403)

    get recording_url(call)

    assert_response :not_found
    refute path.exist?
  ensure
    FileUtils.rm_f(path) if path
  end

  test "non-super-admin tenant cannot serve another tenant's recording" do
    sign_out_tenant
    other = tenants(:other)
    other.update!(password: "test-password-1234", password_confirmation: "test-password-1234", admin: false)
    sign_in_tenant other

    # The legit_completed call belongs to the default tenant.
    call = calls(:legit_completed)
    path = Rails.root.join("storage/recordings/#{call.call_sid}.wav")
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "RIFF dummy wav data")
    call.update!(recording_local_path: path.to_s)

    get recording_url(call)
    assert_response :not_found
  ensure
    FileUtils.rm_f(path) if path
  end

  private

  def sign_in_tenant(tenant)
    post tenant_session_url, params: { tenant: { email: tenant.email, password: "test-password-1234" } }
  end

  def sign_out_tenant
    delete destroy_tenant_session_url
  end
end
