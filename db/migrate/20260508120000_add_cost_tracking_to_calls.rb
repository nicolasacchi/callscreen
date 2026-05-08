class AddCostTrackingToCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :calls, :answered_at,         :datetime
    add_column :calls, :hung_up_at,          :datetime
    add_column :calls, :billable_seconds,    :integer
    add_column :calls, :moonshot_tokens_in,  :integer
    add_column :calls, :moonshot_tokens_out, :integer
    add_column :calls, :telnyx_cost_usd,     :decimal, precision: 12, scale: 8
    add_column :calls, :moonshot_cost_usd,   :decimal, precision: 12, scale: 8
    add_column :calls, :ai_classification_source, :string
  end
end
