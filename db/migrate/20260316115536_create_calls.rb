class CreateCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :calls do |t|
      t.string :call_sid
      t.string :from_number
      t.string :to_number
      t.integer :status, default: 0, null: false
      t.text :screening_transcript
      t.text :ai_classification
      t.string :recording_url
      t.string :recording_local_path
      t.text :voicemail_transcript
      t.integer :duration_seconds
      t.references :contact, null: true, foreign_key: true
      t.datetime :notified_at

      t.timestamps
    end
    add_index :calls, :call_sid, unique: true
    add_index :calls, :from_number
    add_index :calls, :status
    add_index :calls, :created_at
  end
end
