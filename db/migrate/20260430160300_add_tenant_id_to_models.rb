class AddTenantIdToModels < ActiveRecord::Migration[8.1]
  # Add tenant_id FKs to calls, contacts, rules, and audit_logs.
  #
  # For audit_logs we ALSO rename admin_user_id → actor_id (the actor is now
  # a Tenant rather than an AdminUser), and make it nullable so system-
  # initiated entries (e.g. auto_blacklist) can be recorded without an actor.

  def up
    default_tenant_id = select_value("SELECT id FROM tenants WHERE default_tenant = 1 LIMIT 1")
    raise "no default tenant present; run PromoteExistingAdminToDefaultTenant first" unless default_tenant_id

    add_reference :calls,    :tenant, foreign_key: { to_table: :tenants }
    add_reference :contacts, :tenant, foreign_key: { to_table: :tenants }
    add_reference :rules,    :tenant, foreign_key: { to_table: :tenants }

    execute ActiveRecord::Base.sanitize_sql([ "UPDATE calls    SET tenant_id = ? WHERE tenant_id IS NULL", default_tenant_id ])
    execute ActiveRecord::Base.sanitize_sql([ "UPDATE contacts SET tenant_id = ? WHERE tenant_id IS NULL", default_tenant_id ])
    execute ActiveRecord::Base.sanitize_sql([ "UPDATE rules    SET tenant_id = ? WHERE tenant_id IS NULL", default_tenant_id ])

    change_column_null :calls,    :tenant_id, false
    change_column_null :contacts, :tenant_id, false
    change_column_null :rules,    :tenant_id, false

    # Contact uniqueness moves from global phone to (tenant_id, phone)
    remove_index :contacts, :phone
    add_index    :contacts, [ :tenant_id, :phone ], unique: true

    # audit_logs.admin_user_id → actor_id, nullable, plus new tenant_id
    rename_column      :audit_logs, :admin_user_id, :actor_id
    rename_index       :audit_logs, "index_audit_logs_on_admin_user_id", "index_audit_logs_on_actor_id"
    change_column_null :audit_logs, :actor_id, true

    add_reference :audit_logs, :tenant, foreign_key: { to_table: :tenants }
    execute ActiveRecord::Base.sanitize_sql([ "UPDATE audit_logs SET tenant_id = ? WHERE tenant_id IS NULL", default_tenant_id ])
  end

  def down
    remove_reference :audit_logs, :tenant, foreign_key: true
    change_column_null :audit_logs, :actor_id, false
    rename_index   :audit_logs, "index_audit_logs_on_actor_id", "index_audit_logs_on_admin_user_id"
    rename_column  :audit_logs, :actor_id, :admin_user_id

    remove_index   :contacts, [ :tenant_id, :phone ]
    add_index      :contacts, :phone, unique: true

    remove_reference :rules,    :tenant, foreign_key: true
    remove_reference :contacts, :tenant, foreign_key: true
    remove_reference :calls,    :tenant, foreign_key: true
  end
end
