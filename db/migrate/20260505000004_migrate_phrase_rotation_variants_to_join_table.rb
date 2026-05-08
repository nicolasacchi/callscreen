class MigratePhraseRotationVariantsToJoinTable < ActiveRecord::Migration[8.1]
  # Splits each tenant's `phrase_rotation_variants` CSV (e.g. "informal_tu,direct")
  # into TenantPhrase rows pointing at the seeded shared phrases.
  # Unmapped slugs are logged + audited; the CSV column stays for one
  # release as safety net (dropped in a follow-up migration).
  def up
    Tenant.where.not(phrase_rotation_variants: [ nil, "" ]).find_each do |tenant|
      slugs = tenant.phrase_rotation_variants.to_s.split(",").map(&:strip).reject(&:empty?)
      slugs.each_with_index do |slug, idx|
        phrase = Phrase.where(slug: slug)
                       .where("tenant_id IS NULL OR tenant_id = ?", tenant.id)
                       .first
        if phrase.nil?
          Rails.logger.warn(
            "MigratePhraseRotationVariantsToJoinTable: tenant=#{tenant.id} slug=#{slug.inspect} not found, dropping"
          )
          AuditLog.create!(
            tenant: tenant, actor: nil,
            action: "phrase_csv_unmapped",
            subject_type: "Tenant", subject_id: tenant.id,
            metadata: { slug: slug }
          )
          next
        end
        next if TenantPhrase.where(tenant_id: tenant.id, phrase_id: phrase.id).exists?
        TenantPhrase.create!(tenant: tenant, phrase: phrase, position: idx)
      end
    end
  end

  def down
    TenantPhrase.delete_all
  end
end
