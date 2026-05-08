class Phrase < ApplicationRecord
  # Reserved slugs from the seeded shared catalog — user-authored phrases
  # cannot use these. Source of truth for the seed in
  # db/migrate/20260505000003_populate_system_phrases.rb.
  RESERVED_SYSTEM_SLUGS = %w[
    formal_lei informal_tu business_meeting brief_lei brief_tu
    apologetic direct warm delegate_voicemail bilingual_short
    clarify voicemail_prompt goodbye_spam goodbye_short no_answer
  ].freeze

  KINDS = %w[
    user
    system_clarify system_voicemail_prompt
    system_goodbye_spam system_goodbye_short system_no_answer
  ].freeze

  RENDER_STATUSES = %w[pending rendering rendered failed].freeze
  TIMES_OF_DAY    = %w[any morning afternoon evening night].freeze
  DAYS_OF_WEEK    = %w[any weekday weekend monday tuesday wednesday thursday friday saturday sunday].freeze

  SLUG_FORMAT     = /\A[a-z0-9_]{1,40}\z/

  belongs_to :tenant, optional: true                # nil for shared/system

  has_many :phrase_tags,    dependent: :destroy
  has_many :tags,           through: :phrase_tags
  has_many :contact_phrases, dependent: :destroy
  has_many :contacts,       through: :contact_phrases
  has_many :tenant_phrases, dependent: :destroy
  has_many :tenants_via_default_pool, through: :tenant_phrases, source: :tenant

  validates :slug, presence: true, format: { with: SLUG_FORMAT }
  validates :slug, uniqueness: { scope: :tenant_id }
  validates :label, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :render_status, inclusion: { in: RENDER_STATUSES }
  validates :time_of_day, inclusion: { in: TIMES_OF_DAY }
  validates :day_of_week, inclusion: { in: DAYS_OF_WEEK }
  validate  :at_least_one_language
  validate  :reserved_slug_only_for_system_rows
  validate  :forbid_system_kind_change_on_persisted

  before_save :reset_render_on_text_change
  after_commit :enqueue_render_if_text_changed, on: [ :create, :update ]
  after_destroy_commit :schedule_wav_cleanup

  scope :rendered, -> { where(render_status: "rendered") }
  scope :pending,  -> { where(render_status: "pending") }

  scope :with_text, ->(lang) {
    raise ArgumentError, "lang must be 'it' or 'en'" unless %w[it en].include?(lang.to_s)
    lang.to_s == "it" ? where.not(text_it: [ nil, "" ]) : where.not(text_en: [ nil, "" ])
  }

  # Matches phrases whose day_of_week is compatible with the given Date
  # or DayOfWeekSlot symbol. A phrase is compatible if its day_of_week
  # is `any`, the specific day symbol, or the matching weekday/weekend
  # bucket.
  scope :matching_day, ->(day_or_date) {
    eligible = DayOfWeekSlot.eligible_values(day_or_date)
    where(day_of_week: eligible)
  }

  # Phrases visible to a given tenant: shared + own. Column qualified
  # with the table name so the scope composes safely with joins onto
  # tables that also have a `tenant_id` column (tenant_phrases, etc.).
  scope :visible_to, ->(tenant) {
    return where(phrases: { tenant_id: nil }) unless tenant
    where("phrases.tenant_id IS NULL OR phrases.tenant_id = ?", tenant.id)
  }

  # Returns the text in the requested language, falling back to the
  # other language if missing. Mirrors the old GreetingCatalog::Variant#text.
  def text(lang)
    lang = lang.to_s
    case lang
    when "it" then text_it.presence || text_en.presence
    when "en" then text_en.presence || text_it.presence
    else
      text_it.presence || text_en.presence
    end
  end

  def system?
    kind != "user"
  end

  private

  def at_least_one_language
    return if text_it.present? || text_en.present?
    errors.add(:base, "phrase must have text in at least one language")
  end

  def reserved_slug_only_for_system_rows
    return if tenant_id.nil?  # shared rows authored by the seed are exempt
    return unless RESERVED_SYSTEM_SLUGS.include?(slug)
    errors.add(:slug, "is reserved by the system catalog")
  end

  def forbid_system_kind_change_on_persisted
    return unless persisted? && kind_changed?
    return if kind_was == "user"  # user → user changes are fine
    errors.add(:kind, "system phrases cannot change kind")
  end

  def reset_render_on_text_change
    return unless persisted?
    return unless text_it_changed? || text_en_changed?
    self.render_status     = "pending"
    self.last_render_error = nil
  end

  def enqueue_render_if_text_changed
    # On create: always enqueue. On update: only when text changed.
    if previously_new_record?
      return enqueue_render!
    end
    return unless saved_change_to_text_it? || saved_change_to_text_en?
    enqueue_render!
  end

  def enqueue_render!
    PhraseRenderJob.perform_later(id)
  rescue StandardError => e
    Rails.logger.warn("Phrase##{id} enqueue_render! failed: #{e.class}: #{e.message}")
  end

  def schedule_wav_cleanup
    PhraseCleanupJob.set(wait: 10.minutes).perform_later(slug)
  rescue StandardError => e
    Rails.logger.warn("Phrase##{id} schedule_wav_cleanup failed: #{e.class}: #{e.message}")
  end
end
