class AddTrollSegmentIndexToCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :calls, :troll_segment_index, :integer, default: 0, null: false
  end
end
