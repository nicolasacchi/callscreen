require "test_helper"

# The e2e inspector exposes Call/Tenant/Contact state behind the synthetic
# token. Its auth gating, E2E_TENANT_SLUG confinement (fail-closed), and
# sensitive-field redaction are security-load-bearing and were untested.
class E2eInspectorControllerTest < ActionDispatch::IntegrationTest
  setup { @tenant = tenants(:default) }

  teardown do
    ENV.delete("SYNTHETIC_WEBHOOK_TOKEN")
    ENV.delete("E2E_TENANT_SLUG")
  end

  test "401 when SYNTHETIC_WEBHOOK_TOKEN is unset (invisible in non-e2e deployments)" do
    ENV.delete("SYNTHETIC_WEBHOOK_TOKEN")
    get e2e_tenant_url(slug: @tenant.slug, synthetic_token: "anything")
    assert_response :unauthorized
  end

  test "401 on token mismatch" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-tok"
    get e2e_tenant_url(slug: @tenant.slug, synthetic_token: "wrong")
    assert_response :unauthorized
  end

  test "tenant JSON redacts password + token fields" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-tok"
    get e2e_tenant_url(slug: @tenant.slug, synthetic_token: "syn-tok")
    assert_response :success
    body = JSON.parse(@response.body)
    assert_not body.key?("encrypted_password")
    assert_not body.key?("reset_password_token")
    assert_not body.key?("unlock_token")
  end

  test "scoped to E2E_TENANT_SLUG: a tenant outside the scope is 404" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-tok"
    ENV["E2E_TENANT_SLUG"] = "other"
    get e2e_tenant_url(slug: @tenant.slug, synthetic_token: "syn-tok") # asking for 'default'
    assert_response :not_found
  end

  test "fail-closed: scope slug set but no such tenant exists → 404, no leak" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-tok"
    ENV["E2E_TENANT_SLUG"] = "nonexistent-xyz"
    get e2e_tenant_url(slug: @tenant.slug, synthetic_token: "syn-tok")
    assert_response :not_found
  end

  test "cross-tenant call lookup is 404 when scoped to another tenant" do
    ENV["SYNTHETIC_WEBHOOK_TOKEN"] = "syn-tok"
    ENV["E2E_TENANT_SLUG"] = "other"
    @tenant.calls.create!(call_sid: "e2e-foreign", call_control_id: "e2e-foreign",
                          from_number: "+390000000001", status: :completed)
    get e2e_call_url(call_control_id: "e2e-foreign", synthetic_token: "syn-tok")
    assert_response :not_found
  end
end
