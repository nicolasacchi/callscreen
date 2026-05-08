class AddPhraseSettingsToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :language,              :string  # nil = auto / "it" / "en"
    add_column :contacts, :phrase_rotation_index, :integer, null: false, default: 0
  end
end
