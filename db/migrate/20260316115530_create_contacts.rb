class CreateContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :contacts do |t|
      t.string :phone, null: false
      t.string :name
      t.boolean :whitelisted, default: false, null: false
      t.boolean :blacklisted, default: false, null: false
      t.text :notes
      t.integer :calls_count, default: 0, null: false
      t.datetime :last_called_at

      t.timestamps
    end
    add_index :contacts, :phone, unique: true
  end
end
