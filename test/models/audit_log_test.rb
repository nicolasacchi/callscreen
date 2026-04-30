require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @actor  = @tenant
    @call   = calls(:screening)
  end

  test "creates with required fields and serializes metadata" do
    log = AuditLog.create!(
      actor: @actor,
      tenant: @tenant,
      action: "mark_spam",
      subject_type: "Call",
      subject_id: @call.id,
      metadata: { from: "+393331111111", note: "looks spammy" }
    )
    assert log.persisted?
    log.reload
    assert_equal "mark_spam", log.action
    assert_equal "Call", log.subject_type
    assert_equal "+393331111111", log.metadata["from"]
  end

  test "actor and tenant may be nil for system-initiated entries" do
    log = AuditLog.create!(
      actor: nil,
      tenant: @tenant,
      action: "auto_blacklist",
      subject_type: "Contact",
      subject_id: 1,
      metadata: { reason: "test" }
    )
    assert log.persisted?
    assert_nil log.actor_id
    assert_equal @tenant.id, log.tenant_id
  end

  test "requires action, subject_type, subject_id" do
    log = AuditLog.new
    assert_not log.valid?
    assert log.errors[:action].any?
    assert log.errors[:subject_type].any?
    assert log.errors[:subject_id].any?
  end

  test "recent scope orders by created_at desc" do
    a = AuditLog.create!(actor: @actor, tenant: @tenant, action: "x", subject_type: "Call", subject_id: 1, created_at: 2.days.ago)
    b = AuditLog.create!(actor: @actor, tenant: @tenant, action: "y", subject_type: "Call", subject_id: 1, created_at: 1.day.ago)
    assert_equal [ b, a ], AuditLog.recent.where(action: %w[x y]).to_a
  end
end
