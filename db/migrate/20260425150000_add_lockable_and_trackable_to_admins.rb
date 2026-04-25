class AddLockableAndTrackableToAdmins < ActiveRecord::Migration[8.1]
  def change
    change_table :admins, bulk: true do |t|
      # Lockable
      t.integer  :failed_attempts, default: 0, null: false
      t.string   :unlock_token
      t.datetime :locked_at

      # Trackable
      t.integer  :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string   :current_sign_in_ip
      t.string   :last_sign_in_ip
    end

    add_index :admins, :unlock_token, unique: true
  end
end
