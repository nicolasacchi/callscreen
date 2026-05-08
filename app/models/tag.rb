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
end
