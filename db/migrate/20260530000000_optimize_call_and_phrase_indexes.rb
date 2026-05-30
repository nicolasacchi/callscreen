class OptimizeCallAndPhraseIndexes < ActiveRecord::Migration[8.1]
  # Index hygiene from the May 2026 review (DM-1 / DM-2 / PERF-5). Pure index
  # operations — no table rebuild, safe on SQLite.
  def up
    # Backs the time-windowed cost/dashboard aggregations
    # (tenant.calls.where("created_at > ?")) and the tenant-scoped `recent`
    # ordering, which currently fall back to a single-column index + scan.
    add_index :calls, [ :tenant_id, :created_at ] unless index_exists?(:calls, [ :tenant_id, :created_at ])

    # Dead single-column indexes: every call query is tenant-scoped, so SQLite
    # uses the tenant_id-prefixed path. `status` can't help inside that scope,
    # and `from_number` is only ever queried via a leading-wildcard LIKE that
    # no B-tree can serve. Both are pure write-amplification on call inserts.
    remove_index :calls, :status if index_exists?(:calls, :status)
    remove_index :calls, :from_number if index_exists?(:calls, :from_number)

    # Redundant: strict left-prefix of index_phrases_on_resolver_predicate
    # (tenant_id, render_status, time_of_day, day_of_week).
    if index_name_exists?(:phrases, "index_phrases_on_tenant_id_and_render_status_and_time_of_day")
      remove_index :phrases, name: "index_phrases_on_tenant_id_and_render_status_and_time_of_day"
    end
  end

  def down
    remove_index :calls, [ :tenant_id, :created_at ] if index_exists?(:calls, [ :tenant_id, :created_at ])
    add_index :calls, :status unless index_exists?(:calls, :status)
    add_index :calls, :from_number unless index_exists?(:calls, :from_number)
    unless index_name_exists?(:phrases, "index_phrases_on_tenant_id_and_render_status_and_time_of_day")
      add_index :phrases, [ :tenant_id, :render_status, :time_of_day ],
                name: "index_phrases_on_tenant_id_and_render_status_and_time_of_day"
    end
  end
end
