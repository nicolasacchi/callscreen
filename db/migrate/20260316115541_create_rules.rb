class CreateRules < ActiveRecord::Migration[8.1]
  def change
    create_table :rules do |t|
      t.integer :rule_type, null: false
      t.string :value, null: false
      t.integer :action, null: false
      t.boolean :active, default: true, null: false
      t.integer :priority, default: 0, null: false
      t.string :description
      t.integer :hit_count, default: 0, null: false

      t.timestamps
    end
  end
end
