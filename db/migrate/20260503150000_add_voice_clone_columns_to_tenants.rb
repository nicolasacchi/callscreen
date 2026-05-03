class AddVoiceCloneColumnsToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :voice_sample_path,       :string
    add_column :tenants, :voice_clone_consent_at,  :datetime
    add_column :tenants, :voice_clone_active,      :boolean, null: false, default: false
    add_column :tenants, :voice_clone_rendered_at, :datetime
  end
end
