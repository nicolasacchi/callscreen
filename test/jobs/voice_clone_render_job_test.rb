require "test_helper"

class VoiceCloneRenderJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @sample_dir = Rails.root.join("storage", "voice_samples")
    FileUtils.mkdir_p(@sample_dir)
    @sample_file = @sample_dir.join("tenant_#{@tenant.id}.wav")
    File.binwrite(@sample_file, "RIFF dummy")
    @tenant.update!(
      voice_sample_path: "tenant_#{@tenant.id}.wav",
      voice_clone_consent_at: Time.current,
      voice_clone_active: false,
      voice_clone_rendered_at: nil
    )
  end

  teardown { FileUtils.rm_f(@sample_file) }

  test "logs operator instruction when in-container Chatterbox is unavailable" do
    # In test env there's no .venv/bin/python with chatterbox, so the
    # job naturally falls into the host-driven branch and just logs.
    assert_nothing_raised { VoiceCloneRenderJob.new.perform(@tenant.id) }
    @tenant.reload
    assert_nil @tenant.voice_clone_rendered_at,
               "host-driven mode does NOT mark rendered; the operator does"
  end

  test "no-op when sample file is missing on disk" do
    File.unlink(@sample_file)
    assert_nothing_raised { VoiceCloneRenderJob.new.perform(@tenant.id) }
  end

  test "no-op when tenant has no voice_sample_path" do
    @tenant.update_columns(voice_sample_path: nil)
    assert_nothing_raised { VoiceCloneRenderJob.new.perform(@tenant.id) }
  end

  test "discards when tenant id doesn't exist" do
    assert_raises(ActiveRecord::RecordNotFound) do
      VoiceCloneRenderJob.new.perform(999_999)
    end
  end
end
