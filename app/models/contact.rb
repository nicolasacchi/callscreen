class Contact < ApplicationRecord
  include RotatingCursor

  belongs_to :tenant
  has_many :calls, dependent: :nullify

  has_many :contact_phrases, dependent: :destroy
  has_many :phrases,         through: :contact_phrases
  has_many :contact_tags,    dependent: :destroy
  has_many :tags,            through: :contact_tags

  validates :phone, presence: true,
                    uniqueness: { scope: :tenant_id }
  validates :language, inclusion: { in: %w[it en], allow_nil: true }

  scope :whitelisted, -> { where(whitelisted: true) }
  scope :blacklisted, -> { where(blacklisted: true) }

  def display_name
    name.presence || phone
  end

  # Calls from this contact within `within` (default 15 min). Used by the rate
  # limiter in TelnyxController#voice.
  def recent_calls_count(within: 15.minutes)
    calls.where(created_at: within.ago..).count
  end

  # Spam-classified calls from this contact within `within` (default 7 days).
  # Used by the auto-blacklist heuristic.
  def recent_spam_count(within: 7.days)
    calls.where(created_at: within.ago.., status: :spam).count
  end
end
