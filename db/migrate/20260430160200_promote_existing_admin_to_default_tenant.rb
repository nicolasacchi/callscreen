class PromoteExistingAdminToDefaultTenant < ActiveRecord::Migration[8.1]
  # Ensures exactly one Tenant row is marked default_tenant=true and admin=true.
  #
  # Production: the existing admin row gets promoted in place.
  # Dev/test/fresh-start: no existing rows → we create a placeholder one. The
  # operator updates email/password through the admin profile UI after
  # bootstrap (or seeds.rb sets these from ENV in the canonical install).
  #
  # Idempotent: re-running picks up only what isn't already set.

  def up
    operator = select_one("SELECT id, email FROM tenants ORDER BY created_at ASC LIMIT 1")

    if operator.nil?
      # Insert a bootstrap row. The seeds task overwrites email/password
      # from ENV; until then this is a hidden bootstrap row.
      now = Time.current.utc
      execute ActiveRecord::Base.sanitize_sql([
        "INSERT INTO tenants (email, encrypted_password, slug, name, default_tenant, admin, active, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        "bootstrap@example.invalid",
        "x", # placeholder; seeds.rb / admin profile must set a real password
        "bootstrap",
        "Bootstrap",
        true, true, true,
        now, now
      ])
      return
    end

    slug = (operator["email"].to_s.split("@").first.presence || "operator")
            .downcase.gsub(/[^a-z0-9._-]/, "-")
    name = (operator["email"].to_s.split("@").first.presence || "Operator")

    execute ActiveRecord::Base.sanitize_sql([
      "UPDATE tenants SET name = COALESCE(name, ?), slug = COALESCE(slug, ?), default_tenant = ?, admin = ?, active = ? WHERE id = ?",
      name, slug, true, true, true, operator["id"]
    ])
  end

  def down
    # No-op: we never want to demote the operator on rollback.
  end
end
