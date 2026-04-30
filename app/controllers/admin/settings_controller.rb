module Admin
  # Global system settings (transcription engine, retention defaults, etc).
  # Per-tenant settings live on the Tenant model and are managed in
  # Admin::ProfileController. Only super-admins can change global settings.
  class SettingsController < BaseController
    before_action :require_super_admin!

    def show
      @settings = Setting.all_with_defaults
    end

    def update
      errors = []
      params[:settings]&.each do |key, value|
        next unless Setting::DEFAULTS.key?(key)

        begin
          Setting.set(key, value)
        rescue Setting::InvalidValue => e
          errors << e.message
        end
      end

      if errors.empty?
        redirect_to admin_settings_path, notice: "Settings updated."
      else
        redirect_to admin_settings_path, alert: errors.join(". ")
      end
    end
  end
end
