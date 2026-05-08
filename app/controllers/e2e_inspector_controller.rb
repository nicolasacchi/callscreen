# Read-only JSON endpoints for the e2e suite. Token-gated by
# SYNTHETIC_WEBHOOK_TOKEN — same opt-in env var that authorises the
# synthetic webhook path. When the env var is unset, every request to
# this controller returns 401, so the endpoint is invisible in
# production deployments that haven't explicitly enabled e2e.
#
# These exist only so e2e tests can read Call/Tenant/Contact state
# without paying the 3-5 s cost of a `docker exec rails runner` boot
# per assertion.
class E2eInspectorController < ApplicationController
  before_action :require_synthetic_token

  def show_call
    call = Call.find_by(call_control_id: params[:call_control_id])
    return head :not_found unless call
    render json: call.attributes.merge(
      "contact_phone" => call.contact&.phone,
      "tenant_slug"   => call.tenant&.slug
    )
  end

  def show_tenant
    t = Tenant.find_by(slug: params[:slug])
    return head :not_found unless t
    render json: t.attributes.except("encrypted_password", "reset_password_token", "unlock_token")
  end

  def show_contact
    c = Contact.find_by(phone: params[:phone])
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
end
