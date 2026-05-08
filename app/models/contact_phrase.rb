class ContactPhrase < ApplicationRecord
  belongs_to :contact
  belongs_to :phrase

  validates :contact_id, uniqueness: { scope: :phrase_id }
end
