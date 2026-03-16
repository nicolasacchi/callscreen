class Contact < ApplicationRecord
  has_many :calls, dependent: :nullify

  validates :phone, presence: true, uniqueness: true

  scope :whitelisted, -> { where(whitelisted: true) }
  scope :blacklisted, -> { where(blacklisted: true) }

  def display_name
    name.presence || phone
  end
end
