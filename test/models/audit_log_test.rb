require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @admin = AdminUser.create!(
      email: "audit-admin@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234"
    )
    @call = calls(:screening)
  end

  test "creates with required fields and serializes metadata" do
    log = AuditLog.create!(
      admin_user: @admin,
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

  test "requires action, subject_type, subject_id, admin_user" do
    log = AuditLog.new
    assert_not log.valid?
    assert log.errors[:admin_user].any?
    assert log.errors[:action].any?
    assert log.errors[:subject_type].any?
    assert log.errors[:subject_id].any?
  end

  test "recent scope orders by created_at desc" do
    a = AuditLog.create!(admin_user: @admin, action: "x", subject_type: "Call", subject_id: 1, created_at: 2.days.ago)
    b = AuditLog.create!(admin_user: @admin, action: "y", subject_type: "Call", subject_id: 1, created_at: 1.day.ago)
    assert_equal [ b, a ], AuditLog.recent.to_a
  end
end
