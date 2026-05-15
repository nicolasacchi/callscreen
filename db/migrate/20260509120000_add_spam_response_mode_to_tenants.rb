class AddSpamResponseModeToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :spam_response_mode,     :string,  default: "silent", null: false
    add_column :tenants, :spam_troll_max_seconds, :integer, default: 90,       null: false
  end
end
