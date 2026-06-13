class DropDeadContactPhrasesPosition < ActiveRecord::Migration[8.1]
  # contact_phrases.position is read NOWHERE: PhrasePoolResolver orders the
  # per-contact pool by id, and only the tenant default pool (tenant_phrases)
  # honors a position column. Drop the dead column (P3-8 / DM-3). SQLite rebuilds
  # the table; the unique (contact_id, phrase_id) index survives.
  def up
    remove_column :contact_phrases, :position
  end

  def down
    add_column :contact_phrases, :position, :integer, default: 0, null: false
  end
end
