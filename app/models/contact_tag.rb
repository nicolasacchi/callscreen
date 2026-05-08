class ContactTag < ApplicationRecord
  belongs_to :contact
  belongs_to :tag

  validates :contact_id, uniqueness: { scope: :tag_id }
end
