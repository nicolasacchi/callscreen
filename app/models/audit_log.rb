class AuditLog < ApplicationRecord
  # The actor is the Tenant who performed the action (a logged-in user).
  # System-initiated entries (e.g. auto_blacklist) leave actor_id NULL.
  belongs_to :actor,  class_name: "Tenant", foreign_key: :actor_id, optional: true
  # The tenant whose data the action operated on. Optional only for legacy
  # rows or system-wide events; new entries should always set it.
  belongs_to :tenant, optional: true

  serialize :metadata, coder: JSON

  validates :action, presence: true
  validates :subject_type, presence: true
  validates :subject_id, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
