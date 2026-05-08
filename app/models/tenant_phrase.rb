class TenantPhrase < ApplicationRecord
  belongs_to :tenant
  belongs_to :phrase

  validates :tenant_id, uniqueness: { scope: :phrase_id }
end
