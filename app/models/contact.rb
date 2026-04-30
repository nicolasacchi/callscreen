class Contact < ApplicationRecord
  belongs_to :tenant
  has_many :calls, dependent: :nullify

  validates :phone, presence: true,
                    uniqueness: { scope: :tenant_id }

  scope :whitelisted, -> { where(whitelisted: true) }
  scope :blacklisted, -> { where(blacklisted: true) }

  def display_name
    name.presence || phone
  end

  # Calls from this contact within `within` (default 24h). Used by the rate
  # limiter in TelnyxController#voice.
  def recent_calls_count(within: 24.hours)
    calls.where(created_at: within.ago..).count
  end

  # Spam-classified calls from this contact within `within` (default 7 days).
  # Used by the auto-blacklist heuristic.
  def recent_spam_count(within: 7.days)
    calls.where(created_at: within.ago.., status: :spam).count
  end
end
