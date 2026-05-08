class Call < ApplicationRecord
  belongs_to :tenant
  belongs_to :contact, optional: true, counter_cache: true

  enum :status, {
    initiated: 0,
    screening: 1,
    spam: 2,
    legit: 3,
    uncertain: 4,
    recording: 5,
    completed: 6,
    failed: 7,
    unknown: 8         # caller said nothing — no enough signal to classify
  }

  FLOW_STATES = %w[
    initiated
    answered
    screening_prompt_playing
    screening_recording
    processing
    greeting_playing
    awaiting_speech
    classifying
    clarification_playing
    clarification_awaiting_speech
    voicemail_prompt_playing
    recording
    transfer_dialing
    hanging_up_after_speak
    done
  ].freeze

  serialize :ai_classification, coder: JSON

  validates :flow_state, inclusion: { in: FLOW_STATES }

  scope :today,        -> { where(created_at: Time.current.all_day) }
  scope :recent,       -> { order(created_at: :desc) }
  scope :unattributed, -> { where(unattributed: true) }

  def contact_name
    contact&.display_name || from_number
  end

  def ai_reason
    ai_classification&.dig("reason")
  end

  def ai_confidence
    ai_classification&.dig("confidence")
  end

  def llm_classified?
    ai_classification_source == "llm"
  end

  def total_cost_usd
    (telnyx_cost_usd || 0).to_f + (moonshot_cost_usd || 0).to_f
  end
end
