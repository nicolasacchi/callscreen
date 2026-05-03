class AddVoiceRotationToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :voice_rotation_enabled, :boolean, null: false, default: false
    add_column :tenants, :voice_rotation_voices,  :string  # comma-separated voice ids
    add_column :tenants, :voice_rotation_index,   :integer, null: false, default: 0
  end
end
