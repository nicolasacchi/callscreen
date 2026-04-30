class AddCallControlColumnsToCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :calls, :flow_state,      :string,  null: false, default: "initiated"
    add_column :calls, :unattributed,    :boolean, null: false, default: false
    add_column :calls, :call_control_id, :string

    add_index :calls, [ :tenant_id, :flow_state ]
    add_index :calls, :call_control_id, unique: true
    add_index :calls, [ :tenant_id, :unattributed ]
  end
end
