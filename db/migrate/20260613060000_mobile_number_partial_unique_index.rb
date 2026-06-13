class MobileNumberPartialUniqueIndex < ActiveRecord::Migration[8.1]
  # Mirror dedicated_number's partial unique index (DM-2): the non-partial index
  # treated '' / NULL as conflicting values, so two tenants couldn't both leave
  # mobile_number blank. With `where: mobile_number IS NOT NULL`, the allow_nil
  # uniqueness engages and multiple unset tenants coexist. A before_validation on
  # Tenant now nilifies blank values so '' can't sneak past the partial index.
  def up
    execute "UPDATE tenants SET mobile_number = NULL WHERE mobile_number = ''"
    execute "UPDATE tenants SET dedicated_number = NULL WHERE dedicated_number = ''"
    remove_index :tenants, :mobile_number, name: "index_tenants_on_mobile_number" if index_name_exists?(:tenants, "index_tenants_on_mobile_number")
    add_index :tenants, :mobile_number, unique: true, where: "mobile_number IS NOT NULL", name: "index_tenants_on_mobile_number"
  end

  def down
    remove_index :tenants, name: "index_tenants_on_mobile_number" if index_name_exists?(:tenants, "index_tenants_on_mobile_number")
    add_index :tenants, :mobile_number, unique: true, name: "index_tenants_on_mobile_number"
  end
end
