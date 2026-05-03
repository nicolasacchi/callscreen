require "test_helper"

module Admin
  class VoiceSamplesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
      FileUtils.rm_rf(VoiceSamplesController::SAMPLE_DIR)
    end

    teardown { FileUtils.rm_rf(VoiceSamplesController::SAMPLE_DIR) }

    test "create accepts a small WAV upload + records consent" do
      file = Rack::Test::UploadedFile.new(
        StringIO.new("RIFF dummy wav data"), "audio/wav", original_filename: "ignored.wav"
      )

      post admin_voice_sample_url, params: {
        voice_sample: file,
        voice_clone_consent: "1"
      }
      assert_redirected_to edit_admin_profile_path

      @tenant.reload
      assert_equal "tenant_#{@tenant.id}.wav", @tenant.voice_sample_path
      assert_not_nil @tenant.voice_clone_consent_at
      assert_nil @tenant.voice_clone_rendered_at, "fresh upload clears any prior render timestamp"

      assert File.exist?(VoiceSamplesController::SAMPLE_DIR.join(@tenant.voice_sample_path))
    end

    test "create rejects oversized files" do
      big = StringIO.new("X" * (VoiceSamplesController::MAX_BYTES + 1))
      file = Rack::Test::UploadedFile.new(big, "audio/wav", original_filename: "big.wav")
      post admin_voice_sample_url, params: { voice_sample: file }
      assert_redirected_to edit_admin_profile_path
      assert_match(/too large/i, flash[:alert])
      @tenant.reload
      assert_nil @tenant.voice_sample_path
    end

    test "create rejects unsafe MIME types" do
      file = Rack::Test::UploadedFile.new(
        StringIO.new("not audio"), "application/octet-stream",
        original_filename: "shellcode.bin"
      )
      post admin_voice_sample_url, params: { voice_sample: file }
      assert_redirected_to edit_admin_profile_path
      assert_match(/Unsupported file type/i, flash[:alert])
      @tenant.reload
      assert_nil @tenant.voice_sample_path
    end

    test "create without a file shows a friendly error" do
      post admin_voice_sample_url, params: { voice_clone_consent: "1" }
      assert_redirected_to edit_admin_profile_path
      assert_match(/Choose a/i, flash[:alert])
    end

    test "destroy removes sample + clears clone fields + deletes _t<id> dirs" do
      # Seed an "uploaded" sample + a fake cloned audio dir
      FileUtils.mkdir_p(VoiceSamplesController::SAMPLE_DIR)
      File.binwrite(VoiceSamplesController::SAMPLE_DIR.join("tenant_#{@tenant.id}.wav"), "RIFF")
      cloned_dir = Rails.root.join("storage", "greetings", "informal_tu", "_t#{@tenant.id}")
      FileUtils.mkdir_p(cloned_dir)
      File.binwrite(cloned_dir.join("natural.wav"), "RIFF")
      @tenant.update!(
        voice_sample_path: "tenant_#{@tenant.id}.wav",
        voice_clone_consent_at: Time.current,
        voice_clone_active: false,
        voice_clone_rendered_at: Time.current
      )

      delete admin_voice_sample_url
      assert_redirected_to edit_admin_profile_path

      @tenant.reload
      assert_nil @tenant.voice_sample_path
      assert_nil @tenant.voice_clone_consent_at
      assert_nil @tenant.voice_clone_rendered_at
      assert_not @tenant.voice_clone_active
      refute File.exist?(VoiceSamplesController::SAMPLE_DIR.join("tenant_#{@tenant.id}.wav"))
      refute Dir.exist?(cloned_dir)
    ensure
      FileUtils.rm_rf(cloned_dir) if defined?(cloned_dir)
    end

    test "enqueue_render queues a VoiceCloneRenderJob when sample exists" do
      @tenant.update!(
        voice_sample_path: "tenant_#{@tenant.id}.wav",
        voice_clone_consent_at: Time.current
      )
      assert_enqueued_jobs 1, only: VoiceCloneRenderJob do
        post admin_enqueue_voice_clone_render_url
      end
      assert_redirected_to edit_admin_profile_path
    end

    test "enqueue_render refuses when no sample uploaded" do
      assert_no_enqueued_jobs only: VoiceCloneRenderJob do
        post admin_enqueue_voice_clone_render_url
      end
      assert_redirected_to edit_admin_profile_path
      assert_match(/Upload a voice sample/i, flash[:alert])
    end
  end
end
