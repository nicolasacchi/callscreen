# Renders a tenant's full greeting catalog using Chatterbox cloned from
# their uploaded voice sample. Two modes:
#
#  - In-container: if scripts/clone_render.py + Chatterbox are present in
#    the container's Python env, the job invokes it directly.
#  - Host-driven (v1 default): the production image doesn't ship with
#    Chatterbox; the job logs an instruction and the operator runs
#    `bin/clone_render <id>` on the host. The rendered files land in the
#    shared storage volume which the production container reads.
#
# Either way, on success the job sets tenant.voice_clone_rendered_at.
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
        "VoiceCloneRenderJob: in-container render unavailable. " \
        "Operator: run `bin/clone_render #{tenant.id}` on the host."
      )
      # We don't mark rendered_at — the operator's host run sets that
      # via a separate Tenant.update! after clone_render completes.
    end
  end

  private

  def in_container_render_available?
    # Tests never invoke the real script — the test env's job assertions
    # only verify the job enqueued/finished cleanly without running
    # heavy ML code. The script-running path is exercised by the
    # operator manually via bin/clone_render in dev.
    return false if Rails.env.test?
    venv_python = Rails.root.join(".venv", "bin", "python").to_s
    return false unless File.executable?(venv_python)
    out = `#{venv_python.shellescape} -c "import chatterbox" 2>&1`
    $?.success? && !out.include?("ImportError")
  rescue StandardError
    false
  end

  def run_in_container(tenant, sample_abs)
    script = Rails.root.join("scripts", "clone_render.py").to_s
    venv_python = Rails.root.join(".venv", "bin", "python").to_s
    cmd = [ venv_python, script, tenant.id.to_s, "--sample", sample_abs ]
    output = nil
    Open3.popen2e(*cmd) do |_in, out, wait_thr|
      output = out.read
      status = wait_thr.value
      if status.success? && output.to_s.include?("RENDERED #{tenant.id}")
        tenant.update!(voice_clone_rendered_at: Time.current)
        Rails.logger.info("VoiceCloneRenderJob: rendered tenant #{tenant.id}")
      else
        Rails.logger.error("VoiceCloneRenderJob failed for tenant #{tenant.id}: #{output.to_s.last(2_000)}")
        raise "clone_render exited non-zero"
      end
    end
  end
end
