class RenameAdminsToTenants < ActiveRecord::Migration[8.1]
  def change
    rename_table :admins, :tenants

    rename_index :tenants, "index_admins_on_email", "index_tenants_on_email"
    rename_index :tenants, "index_admins_on_reset_password_token", "index_tenants_on_reset_password_token"
    rename_index :tenants, "index_admins_on_unlock_token", "index_tenants_on_unlock_token"
  end
end
