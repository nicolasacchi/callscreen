module Admin
  # Each Tenant edits their OWN per-tenant settings here: greeting choice,
  # spam sensitivity, dial-back number, ntfy URL, abuse limits, etc.
  # No tenant_id parameter — always operates on `current_tenant`.
  class ProfilesController < BaseController
    def show
      @tenant = current_tenant
    end

    def edit
      @tenant = current_tenant
    end

    def update
      @tenant = current_tenant
      if @tenant.update(profile_params)
        redirect_to admin_profile_path, notice: "Profile updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def profile_params
      raw = params.require(:tenant).permit(
        :name,
        :mobile_number,
        :forward_back_number,
        :ntfy_url,
        :ntfy_priority,
        :greeting_variant,
        :greeting_voice,
        :greeting_tone,
        :greeting_language,
        :greeting_text,
        :voicemail_prompt,
        :spam_sensitivity,
        :max_recording_seconds,
        :screening_speech_timeout,
        :max_calls_per_caller_per_day,
        :auto_blacklist_threshold,
        :auto_blacklist_window_days,
        :auto_detect_language,
        :voice_clone_active,
        :voice_rotation_enabled,
        voice_rotation_voices: []
      )

      # Multi-checkbox → comma-separated string (DB column is :string, not array)
      if raw.key?(:voice_rotation_voices)
        new_list = Array(raw[:voice_rotation_voices]).reject(&:blank?).join(",")
        # Reset the rotation counter whenever the list changes so the
        # cycle restarts cleanly from the first voice.
        if new_list != current_tenant.voice_rotation_voices.to_s
          raw[:voice_rotation_index] = 0
        end
        raw[:voice_rotation_voices] = new_list
      end

      raw
    end
  end
end
