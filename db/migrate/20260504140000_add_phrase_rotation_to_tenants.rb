class AddPhraseRotationToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :phrase_rotation_enabled,  :boolean, null: false, default: false
    add_column :tenants, :phrase_rotation_variants, :string  # comma-separated variant slugs
    add_column :tenants, :phrase_rotation_index,    :integer, null: false, default: 0
  end
end
