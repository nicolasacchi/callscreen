class Tag < ApplicationRecord
  belongs_to :tenant, optional: true   # nil for shared (rare; usually tenant-owned)

  has_many :phrase_tags,  dependent: :destroy
  has_many :phrases,      through: :phrase_tags
  has_many :contact_tags, dependent: :destroy
  has_many :contacts,     through: :contact_tags

  validates :name, presence: true
  validates :name, uniqueness: { scope: :tenant_id, case_sensitive: false }

  scope :for_tenant, ->(tenant) {
    return where(tenant_id: nil) unless tenant
    where("tenant_id IS NULL OR tenant_id = ?", tenant.id)
  }

  # Assigns a comma-separated tag-name list to a record (Contact/Phrase),
  # creating tenant-owned tags as needed. Single home for the parse + upsert
  # logic the contacts/phrases controllers both used (CQ-6).
  def self.assign_csv(record, names_csv, tenant:)
    names = names_csv.to_s.split(",").map(&:strip).reject(&:empty?).uniq
    record.tags = names.map { |n| find_or_create_by!(tenant: tenant, name: n) }
  end
end
