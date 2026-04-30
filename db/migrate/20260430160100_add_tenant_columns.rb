class AddTenantColumns < ActiveRecord::Migration[8.1]
  def change
    change_table :tenants do |t|
      t.string  :name
      t.string  :slug
      t.string  :mobile_number          # E.164; KEY for History-Info match
      t.string  :forward_back_number    # default = mobile_number
      t.string  :dedicated_number       # B1: tenant's own Telnyx DID (null when sharing)
      t.string  :railsdav_username      # 1:1 link to railsdav-app User.username

      t.string  :ntfy_url
      t.string  :ntfy_priority, default: "default"

      t.string  :greeting_variant,  default: "informal_tu"
      t.string  :greeting_voice,    default: "im_nicola"
      t.string  :greeting_tone,     default: "natural"
      t.string  :greeting_language, default: "it-IT"
      t.text    :greeting_text
      t.text    :voicemail_prompt

      t.float   :spam_sensitivity,                 default: 0.5
      t.integer :max_recording_seconds,            default: 120
      t.string  :screening_speech_timeout,         default: "3"
      t.integer :max_calls_per_caller_per_day,     default: 10
      t.integer :auto_blacklist_threshold,         default: 3
      t.integer :auto_blacklist_window_days,       default: 7

      t.boolean :default_tenant, default: false, null: false
      t.boolean :admin,          default: false, null: false
      t.boolean :active,         default: true,  null: false
    end

    add_index :tenants, :slug,             unique: true
    add_index :tenants, :mobile_number,    unique: true
    add_index :tenants, :dedicated_number, unique: true, where: "dedicated_number IS NOT NULL"
    add_index :tenants, :default_tenant,   unique: true, where: "default_tenant = 1"
  end
end
