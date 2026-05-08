class AddSelectedPhraseSlugToCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :calls, :selected_phrase_slug, :string
  end
end
