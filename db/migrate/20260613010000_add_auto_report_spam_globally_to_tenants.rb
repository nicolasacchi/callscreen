class AddAutoReportSpamGloballyToTenants < ActiveRecord::Migration[8.1]
  # P2-7: per-tenant opt-in to auto-contribute operator-confirmed spam to the
  # shared cross-tenant reputation DB. Default OFF for GDPR posture — the
  # operator must explicitly enable sharing.
  def change
    add_column :tenants, :auto_report_spam_globally, :boolean, default: false, null: false
  end
end
