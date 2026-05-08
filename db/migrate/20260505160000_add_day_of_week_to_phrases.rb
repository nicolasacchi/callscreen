class AddDayOfWeekToPhrases < ActiveRecord::Migration[8.1]
  def change
    add_column :phrases, :day_of_week, :string, null: false, default: "any"
    # Existing index was (tenant_id, render_status, time_of_day); extending
    # to include day_of_week so the resolver predicate hits it cleanly.
    add_index :phrases, [ :tenant_id, :render_status, :time_of_day, :day_of_week ],
              name: "index_phrases_on_resolver_predicate"
  end
end
