# Read-only JSON endpoints for the e2e suite. Token-gated by
# SYNTHETIC_WEBHOOK_TOKEN — same opt-in env var that authorises the
# synthetic webhook path. When the env var is unset, every request to
# this controller returns 401, so the endpoint is invisible in
# production deployments that haven't explicitly enabled e2e.
#
# Defense-in-depth: when E2E_TENANT_SLUG is set, the inspector is confined
# to that single fixture tenant's rows, so even a leaked synthetic token
# cannot enumerate other tenants' calls/contacts/config. The live e2e suite
# only ever reads the "e2e" fixture tenant, so set E2E_TENANT_SLUG=e2e in any
# deployment that runs e2e against it. Unset = unscoped (legacy behavior) —
# in that case production should leave SYNTHETIC_WEBHOOK_TOKEN unset entirely.
#
# These exist only so e2e tests can read Call/Tenant/Contact state
# without paying the 3-5 s cost of a `docker exec rails runner` boot
# per assertion.
class E2eInspectorController < ApplicationController
  before_action :require_synthetic_token

  def show_call
    call = scoped_calls.find_by(call_control_id: params[:call_control_id])
    return head :not_found unless call
    render json: call.attributes.merge(
      "contact_phone" => call.contact&.phone,
      "tenant_slug"   => call.tenant&.slug
    )
  end

  def show_tenant
    t = scoped_tenants.find_by(slug: params[:slug])
    return head :not_found unless t
    render json: t.attributes.except("encrypted_password", "reset_password_token", "unlock_token")
  end

  def show_contact
    c = scoped_contacts.find_by(phone: params[:phone])
    return head :not_found unless c
    render json: c.attributes.merge(
      "phrase_ids" => c.phrase_ids,
      "tag_names"  => c.tags.pluck(:name)
    )
  end

  private

  def require_synthetic_token
    expected = ENV["SYNTHETIC_WEBHOOK_TOKEN"].to_s
    return head :unauthorized if expected.empty?
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(
      params[:synthetic_token].to_s, expected
    )
  end

  # When E2E_TENANT_SLUG is configured, reads are confined to that tenant.
  # If the slug is set but no such tenant exists, scope to nothing
  # (fail-closed) rather than leaking the whole table.
  def e2e_scoped?
    ENV["E2E_TENANT_SLUG"].present?
  end

  def e2e_tenant
    return @e2e_tenant if defined?(@e2e_tenant)
    @e2e_tenant = e2e_scoped? ? Tenant.find_by(slug: ENV["E2E_TENANT_SLUG"]) : nil
  end

  def scoped_tenants
    return Tenant.all unless e2e_scoped?
    e2e_tenant ? Tenant.where(id: e2e_tenant.id) : Tenant.none
  end

  def scoped_calls
    return Call.all unless e2e_scoped?
    e2e_tenant ? e2e_tenant.calls : Call.none
  end

  def scoped_contacts
    return Contact.all unless e2e_scoped?
    e2e_tenant ? e2e_tenant.contacts : Contact.none
  end
end
