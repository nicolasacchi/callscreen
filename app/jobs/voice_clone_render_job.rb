# Renders a tenant's full greeting catalog using Chatterbox cloned from
# their uploaded voice sample. Two modes:
#
#  - In-container: production image ships /opt/tts_venv with Chatterbox.
#    The job invokes scripts/clone_render.py inside the container via
#    SolidQueue. Tenant.voice_clone_rendered_at is set on success.
#  - Host-driven (legacy fallback): if the venv isn't present (e.g. an
#    older image), the job logs an instruction and the operator runs
#    `bin/clone_render <id>` on the host. Same shared storage volume.
#
# Either way, on success the tenant.voice_clone_rendered_at gets set.
class VoiceCloneRenderJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(tenant_id)
    tenant = Tenant.find(tenant_id)
    return if tenant.voice_sample_path.blank?

    sample_abs = Rails.root.join("storage", "voice_samples", tenant.voice_sample_path).to_s
    unless File.exist?(sample_abs)
      Rails.logger.warn("VoiceCloneRenderJob: sample missing for tenant #{tenant_id}: #{sample_abs}")
      return
    end

    if in_container_render_available?
      run_in_container(tenant, sample_abs)
    else
      Rails.logger.info(
        "VoiceCloneRenderJob: TTS venv not found (#{tts_python.inspect}). " \
        "Run `bin/clone_render #{tenant.id}` on the host instead."
      )
    end
  end

  private

  def in_container_render_available?
    return false if Rails.env.test?
    File.executable?(tts_python.to_s)
  rescue StandardError
    false
  end

  # In production the venv lives at /opt/tts_venv (built by the
  # Dockerfile's tts_build stage). Override via TTS_VENV_PYTHON for
  # other deployments. Local dev fallback is .venv at the repo root.
  def tts_python
    return ENV["TTS_VENV_PYTHON"] if ENV["TTS_VENV_PYTHON"].present?
    candidates = [ "/opt/tts_venv/bin/python", Rails.root.join(".venv", "bin", "python").to_s ]
    candidates.find { |p| File.executable?(p) }
  end

  def run_in_container(tenant, sample_abs)
    script = Rails.root.join("scripts", "clone_render.py").to_s
    cmd = [ tts_python, script, tenant.id.to_s, "--sample", sample_abs ]

    Rails.logger.info("VoiceCloneRenderJob: running #{cmd.join(' ')}")
    output = nil
    Open3.popen2e(*cmd) do |_in, out, wait_thr|
      output = out.read
      status = wait_thr.value
      if status.success? && output.to_s.include?("RENDERED #{tenant.id}")
        tenant.update!(voice_clone_rendered_at: Time.current)
        Rails.logger.info("VoiceCloneRenderJob: rendered tenant #{tenant.id}")
      else
        Rails.logger.error("VoiceCloneRenderJob failed for tenant #{tenant.id}: #{output.to_s.last(4_000)}")
        raise "clone_render exited non-zero"
      end
    end
  end
end
