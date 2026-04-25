class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :admin_user, null: false, foreign_key: { to_table: :admins }
      t.string :action, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.text :metadata
      t.datetime :created_at, null: false
    end

    add_index :audit_logs, [ :subject_type, :subject_id ]
    add_index :audit_logs, :created_at
  end
end
