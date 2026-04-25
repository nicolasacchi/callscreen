class AuditLog < ApplicationRecord
  belongs_to :admin_user

  serialize :metadata, coder: JSON

  validates :action, presence: true
  validates :subject_type, presence: true
  validates :subject_id, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
