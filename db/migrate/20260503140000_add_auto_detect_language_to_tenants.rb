class AddAutoDetectLanguageToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :auto_detect_language, :boolean, null: false, default: true
  end
end
