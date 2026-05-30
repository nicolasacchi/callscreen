class CreatePhrasesAndTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.references :tenant, foreign_key: true, null: true   # nullable for shared
      t.string :name, null: false
      t.timestamps
    end
    add_index :tags, [ :tenant_id, :name ], unique: true

    create_table :phrases do |t|
      t.references :tenant, foreign_key: true, null: true   # nullable for shared/system
      t.string  :slug,           null: false, limit: 40
      t.string  :label,          null: false
      t.string  :kind,           null: false, default: "user"
      t.text    :text_it
      t.text    :text_en
      t.string  :time_of_day,    null: false, default: "any"
      t.string  :render_status,  null: false, default: "pending"
      t.datetime :last_rendered_at
      t.string :last_render_error
      t.timestamps
    end
    # Slug uniqueness scoped per tenant (system rows have tenant_id NULL).
    add_index :phrases, [ :tenant_id, :slug ], unique: true
    # Resolver predicate index — most queries filter on these three.
    add_index :phrases, [ :tenant_id, :render_status, :time_of_day ]

    create_table :phrase_tags do |t|
      t.references :phrase, null: false, foreign_key: true
      t.references :tag,    null: false, foreign_key: true
      t.timestamps
    end
    add_index :phrase_tags, [ :phrase_id, :tag_id ], unique: true

    create_table :contact_phrases do |t|
      t.references :contact, null: false, foreign_key: true
      t.references :phrase,  null: false, foreign_key: true
      t.integer    :position, null: false, default: 0
      t.timestamps
    end
    add_index :contact_phrases, [ :contact_id, :phrase_id ], unique: true

    create_table :contact_tags do |t|
      t.references :contact, null: false, foreign_key: true
      t.references :tag,     null: false, foreign_key: true
      t.timestamps
    end
    add_index :contact_tags, [ :contact_id, :tag_id ], unique: true

    create_table :tenant_phrases do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :phrase, null: false, foreign_key: true
      t.integer    :position, null: false, default: 0
      t.timestamps
    end
    add_index :tenant_phrases, [ :tenant_id, :phrase_id ], unique: true
  end
end
