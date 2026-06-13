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

  # Leg-lifecycle states actually assigned by the Voice API dispatcher. The
  # pre-Phase-4 TeXML states (processing, greeting_playing, awaiting_speech,
  # classifying, clarification_*, voicemail_prompt_playing) were dead — never
  # assigned anywhere — and were pruned (ARCH-2/CQ-1).
  # NB: "recording" here is the FSM state for the legacy whitelisted-voicemail
  # path; it's distinct from the `status` enum value of the same name.
  FLOW_STATES = %w[
    initiated
    answered
    screening_prompt_playing
    screening_recording
    recording
    transfer_dialing
    bridged
    hanging_up_after_speak
    spam_disclose_playing
    troll_playing
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

  # Per-row total-cost SQL expression (Telnyx + Moonshot, NULL-safe). Single
  # home for the formula the costs dashboard aggregates (CQ-9); mirrors
  # #total_cost_usd above.
  TOTAL_COST_SQL = "COALESCE(telnyx_cost_usd, 0) + COALESCE(moonshot_cost_usd, 0)".freeze

  def self.total_cost_sum_sql
    Arel.sql("SUM(#{TOTAL_COST_SQL})")
  end
end
