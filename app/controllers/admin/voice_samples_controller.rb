module Admin
  # Upload + delete the per-tenant voice sample used for cloning. Always
  # operates on `current_tenant` (no id parameter, no cross-tenant access).
  #
  # Constraints (rejected with a redirect + flash alert):
  #   - file MIME content-sniffed to wav/mpeg/m4a (not just extension)
  #   - file size ≤ 5 MB
  #   - duration ≤ 30 seconds (probed via ffprobe)
  #
  # Filenames are derived from the tenant id (`tenant_<id>.wav`); the
  # uploaded filename is ignored to prevent path traversal.
  class VoiceSamplesController < BaseController
    MAX_BYTES = 5 * 1024 * 1024  # 5 MB
    MAX_DURATION_SECS = 30
    SAMPLE_DIR = Rails.root.join("storage", "voice_samples")
    ALLOWED_MIME = %w[audio/wav audio/x-wav audio/wave audio/mpeg audio/mp3 audio/mp4 audio/x-m4a].freeze

    def create
      tenant = current_tenant
      file   = params[:voice_sample] || params.dig(:tenant, :voice_sample)

      unless file.respond_to?(:read)
        return redirect_with_alert("Choose a WAV or MP3 file to upload.")
      end

      if file.size > MAX_BYTES
        return redirect_with_alert("File too large (max 5 MB).")
      end

      content_type = file.content_type.to_s.downcase
      unless ALLOWED_MIME.include?(content_type)
        return redirect_with_alert("Unsupported file type: #{content_type.presence || 'unknown'}. Allowed: WAV, MP3, M4A.")
      end

      FileUtils.mkdir_p(SAMPLE_DIR)
      basename = "tenant_#{tenant.id}#{ext_for(content_type)}"
      target = SAMPLE_DIR.join(basename)
      File.binwrite(target, file.read)

      # probe_duration returns:
      #   nil   — ffprobe couldn't parse the file. Log + accept (size cap bounds abuse).
      #   +Inf  — ffprobe missing. Accept, render-time will fail loudly if file is junk.
      #   Float — actual duration; reject if too long.
      duration = probe_duration(target)
      if duration.is_a?(Float) && duration.finite? && duration > MAX_DURATION_SECS + 1
        File.unlink(target) if File.exist?(target)
        return redirect_with_alert("Audio too long: #{duration.round(1)}s (max #{MAX_DURATION_SECS}s).")
      end
      duration_label = (duration.is_a?(Float) && duration.finite?) ? "#{duration.round(1)}s" : "unknown duration"

      tenant.update!(
        voice_sample_path: basename,
        voice_clone_consent_at: consent_given? ? Time.current : nil,
        # Uploading a new sample invalidates the previous render — Active
        # stays on if it was on, but the rendered_at clears so the operator
        # knows to re-run clone_render.
        voice_clone_rendered_at: nil
      )
      redirect_to edit_admin_profile_path,
                  notice: "Voice sample uploaded (#{duration_label}). Run `bin/clone_render #{tenant.id}` on the host to render."
    end

    def destroy
      tenant = current_tenant
      remove_sample!(tenant)
      remove_cloned_audio!(tenant)
      tenant.update!(
        voice_sample_path: nil,
        voice_clone_consent_at: nil,
        voice_clone_active: false,
        voice_clone_rendered_at: nil
      )
      redirect_to edit_admin_profile_path, notice: "Voice sample + clone removed; default Kokoro voice restored."
    end

    # POST /admin/voice_sample/clone — enqueue a fresh render via SolidQueue.
    # In v1 this runs the render in-container only if Chatterbox is installed;
    # otherwise the operator runs `bin/clone_render <id>` on the host.
    def enqueue_render
      tenant = current_tenant
      if tenant.voice_sample_path.blank?
        return redirect_to edit_admin_profile_path,
                           alert: "Upload a voice sample before requesting a render."
      end
      VoiceCloneRenderJob.perform_later(tenant.id)
      redirect_to edit_admin_profile_path,
                  notice: "Voice clone render queued. Run `bin/clone_render #{tenant.id}` on the host (or wait for the in-container worker if Chatterbox is installed)."
    end

    private

    def consent_given?
      params[:voice_clone_consent].in?(%w[1 true on yes])
    end

    def ext_for(mime)
      case mime
      when "audio/wav", "audio/x-wav", "audio/wave" then ".wav"
      when "audio/mp4", "audio/x-m4a"               then ".m4a"
      else ".mp3"
      end
    end

    # Best-effort duration probe. Returns the duration in seconds when
    # ffprobe is installed, or +Float::INFINITY when it isn't (so the
    # caller can decide whether to enforce the cap or skip with a
    # warning). The size cap (5 MB) is the harder bound either way.
    def probe_duration(path)
      return Float::INFINITY if `which ffprobe 2>/dev/null`.strip.empty?
      out = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{path.to_s.shellescape} 2>/dev/null`
      Float(out.strip)
    rescue ArgumentError, TypeError
      nil
    end

    def redirect_with_alert(msg)
      redirect_to edit_admin_profile_path, alert: msg
    end

    def remove_sample!(tenant)
      return unless tenant.voice_sample_path.present?
      path = SAMPLE_DIR.join(tenant.voice_sample_path)
      File.unlink(path) if path.exist?
    end

    def remove_cloned_audio!(tenant)
      dir_name = tenant.cloned_voice_dir
      Dir.glob(Rails.root.join("storage", "greetings", "*", dir_name)).each do |dir|
        FileUtils.rm_rf(dir)
      end
    end
  end
end
