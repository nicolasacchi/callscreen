module Admin
  # Super-admin CRUD over the multi-tenant directory. Sub-tenants must use
  # Admin::ProfileController to edit their own row.
  class TenantsController < BaseController
    before_action :require_super_admin!
    before_action :load_tenant, only: [ :show, :edit, :update, :destroy ]

    def index
      @tenants = Tenant.order(default_tenant: :desc, created_at: :asc)
    end

    def show
      @recent_calls = @tenant.calls.recent.limit(20)
    end

    def new
      @tenant = Tenant.new
    end

    def create
      @tenant = Tenant.new(tenant_params)
      # Devise validates :password on create when present; require it here
      # so the operator must set an initial password for the new sub-tenant.
      if params[:tenant][:password].blank?
        @tenant.errors.add(:password, "is required for a new tenant")
        render :new, status: :unprocessable_entity
        return
      end

      if @tenant.save
        redirect_to admin_tenant_path(@tenant), notice: "Tenant #{@tenant.display_name} created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @tenant.update(tenant_params)
        redirect_to admin_tenant_path(@tenant), notice: "Tenant updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @tenant.default?
        redirect_to admin_tenants_path, alert: "Cannot delete the default tenant."
        return
      end

      @tenant.destroy
      redirect_to admin_tenants_path, notice: "Tenant deleted."
    rescue ActiveRecord::DeleteRestrictionError => e
      redirect_to admin_tenants_path, alert: "Cannot delete: #{e.message}"
    end

    private

    def load_tenant
      @tenant = Tenant.find(params[:id])
    end

    def tenant_params
      permitted = [
        :name, :slug, :email, :mobile_number, :forward_back_number,
        :dedicated_number, :railsdav_username,
        :ntfy_url, :ntfy_priority,
        :greeting_variant, :greeting_voice, :greeting_tone, :greeting_language,
        :greeting_text, :voicemail_prompt,
        :spam_sensitivity, :max_recording_seconds, :screening_speech_timeout,
        :max_calls_per_caller_per_day, :auto_blacklist_threshold,
        :auto_blacklist_window_days,
        :admin, :active
      ]
      permitted += [ :password, :password_confirmation ] if params[:tenant][:password].present?
      params.require(:tenant).permit(*permitted)
    end
  end
end
