class AddAdminLocaleToTenants < ActiveRecord::Migration[8.1]
  # P2-4: per-tenant admin-console language. Defaults to Italian (the product's
  # primary audience); operators can switch to English in their profile.
  def change
    add_column :tenants, :admin_locale, :string, default: "it", null: false
  end
end
