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
    unknown: 8,        # caller said nothing — no enough signal to classify
    voicemail: 9       # recording captured but transcription unavailable (P2-5 graceful degradation)
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
  # Snapshot of the railsdav contact-lookup result captured at call.initiated
  # (policy / addressbook / contact_id / spam_metadata). Lets the admin view and
  # ntfy push show the central reputation without a second lookup.
  serialize :external_lookup_meta, coder: JSON

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

  # One-line operator-facing TL;DR of the voicemail (Italian), produced by the
  # classifier (P2-3). Nil for calls classified before this existed or by a
  # non-LLM source.
  def ai_summary
    s = ai_classification&.dig("summary")
    s.presence
  end

  def ai_confidence
    ai_classification&.dig("confidence")
  end

  # --- railsdav lookup snapshot accessors (external_lookup_meta) ---
  def external_policy      = external_lookup_meta&.dig("policy")
  def external_addressbook = external_lookup_meta&.dig("addressbook")
  def external_contact_id  = external_lookup_meta&.dig("contact_id")
  def spam_global_meta     = external_lookup_meta&.dig("spam_metadata") || {}

  # One-line spam evidence forwarded to railsdav's shared spam DB as `notes`, so
  # a globally-reported number records WHY it was flagged (the LLM reason
  # callscreen already computed) instead of a bare number. nil when there's no
  # LLM evidence, so the reporter's blank-notes guard omits it. Control chars
  # stripped + length-capped before it crosses the API boundary.
  def spam_evidence_note
    body = ai_summary.presence || ai_reason.presence
    return nil if body.blank?
    note = body.to_s
    note += " (conf #{confidence_pct}%)" if confidence_pct
    note.gsub(/[\r\n\x00-\x1F\x7F]+/, " ").strip.first(500)
  end

  # AI confidence as a whole-number percentage, or nil when unknown. Single home
  # for the `(confidence * 100).round` idiom duplicated across NotifyJob /
  # TranscribeRecordingJob / the call views (CQ-5).
  def confidence_pct
    return nil if ai_confidence.nil?
    (ai_confidence.to_f * 100).round
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
