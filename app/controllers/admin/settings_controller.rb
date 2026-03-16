module Admin
  class SettingsController < BaseController
    def show
      @settings = Setting.all_with_defaults
    end

    def update
      params[:settings]&.each do |key, value|
        Setting.set(key, value) if Setting::DEFAULTS.key?(key)
      end
      redirect_to admin_settings_path, notice: "Settings updated."
    end
  end
end
