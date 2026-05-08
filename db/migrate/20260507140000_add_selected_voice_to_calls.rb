class AddSelectedVoiceToCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :calls, :selected_voice, :string
  end
end
