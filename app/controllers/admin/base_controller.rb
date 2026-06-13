module Admin
  class BaseController < ApplicationController
    before_action :authenticate_tenant!
    before_action :set_current_tenant
    around_action :switch_locale
    layout "admin"

    helper_method :current_tenant, :super_admin?, :viewing_tenant

    private

    # Render the admin console in the tenant's chosen language (P2-4). Falls
    # back to the app default (:it) when unset or invalid.
    def switch_locale(&action)
      locale = current_tenant&.admin_locale
      locale = I18n.default_locale unless I18n.available_locales.map(&:to_s).include?(locale.to_s)
      I18n.with_locale(locale, &action)
    end

    # The currently logged-in Tenant (Devise resource).
    def current_tenant
      @current_tenant ||= warden.user(:tenant)
    end

    def set_current_tenant
      Current.tenant = current_tenant
    end

    def super_admin?
      current_tenant&.super_admin?
    end

    # Most admin pages operate on the current tenant's data only. Super-admins
    # may "view" another tenant by passing ?tenant_id=… on cross-tenant pages.
    # Per-resource controllers should call `viewing_tenant` to get the active
    # tenant scope, falling back to current_tenant for non-super-admins.
    def viewing_tenant
      if super_admin? && params[:tenant_id].present?
        Tenant.find(params[:tenant_id])
      else
        current_tenant
      end
    end

    def require_super_admin!
      head :forbidden unless super_admin?
    end

    def paginate(scope, per: 25)
      page = [ params[:page].to_i, 1 ].max
      total = scope.count
      offset = (page - 1) * per
      records = scope.offset(offset).limit(per)
      @pagination = {
        current_page: page,
        per_page: per,
        total_count: total,
        total_pages: (total.to_f / per).ceil
      }
      records
    end
  end
end
