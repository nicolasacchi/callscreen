class AddRailsdavSnapshotToCalls < ActiveRecord::Migration[8.1]
  # Persist the railsdav contact-lookup result on the Call. Today the rich
  # Result (policy / global-spam reputation / contact_id) is computed on the
  # webhook hot path, fed to CallPolicy, then discarded — so the operator can't
  # see WHY a call was screened without leaving the app, the ntfy push can't show
  # the cross-tenant spam corroboration, and spam_confidence_for reads a
  # report_count that was never stored. One snapshot column unblocks all three.
  def change
    add_column :calls, :spam_global, :boolean, null: false, default: false
    # JSON blob (serialized in the model, matching ai_classification): holds
    # policy, addressbook, contact_id, and the spam_metadata hash
    # (first_reported_at, last_seen_at, source, report_count, notes).
    add_column :calls, :external_lookup_meta, :text
  end
end
