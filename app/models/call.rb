class Call < ApplicationRecord
  belongs_to :contact, optional: true, counter_cache: true

  enum :status, {
    initiated: 0,
    screening: 1,
    spam: 2,
    legit: 3,
    uncertain: 4,
    recording: 5,
    completed: 6,
    failed: 7
  }

  serialize :ai_classification, coder: JSON

  scope :today, -> { where(created_at: Time.current.all_day) }
  scope :recent, -> { order(created_at: :desc) }

  def contact_name
    contact&.display_name || from_number
  end

  def ai_reason
    ai_classification&.dig("reason")
  end

  def ai_confidence
    ai_classification&.dig("confidence")
  end
end
