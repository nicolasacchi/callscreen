class AddContactCreatedAtIndexToCalls < ActiveRecord::Migration[8.1]
  # PERF-1. The per-caller rate limiter (CallPolicy#rate_limited? →
  # Contact#recent_calls_count) runs on EVERY inbound call and counts a
  # contact's calls within a created_at window. The single-column
  # index_calls_on_contact_id forces a created_at scan inside that contact's
  # calls — worst for a frequent caller, which is exactly the rate-limiter's
  # target. A composite (contact_id, created_at) serves the window directly and
  # makes the single-column contact_id index a redundant left-prefix (it still
  # covers the calls→contacts FK lookups). Pure index op — SQLite-safe, no
  # table rebuild.
  def up
    add_index :calls, [ :contact_id, :created_at ] unless index_exists?(:calls, [ :contact_id, :created_at ])
    remove_index :calls, :contact_id, name: "index_calls_on_contact_id" if index_name_exists?(:calls, "index_calls_on_contact_id")
  end

  def down
    add_index :calls, :contact_id unless index_exists?(:calls, :contact_id)
    remove_index :calls, [ :contact_id, :created_at ] if index_exists?(:calls, [ :contact_id, :created_at ])
  end
end
