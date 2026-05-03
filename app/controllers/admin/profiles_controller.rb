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
      params.require(:tenant).permit(
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
        :voice_clone_active
      )
    end
  end
end
