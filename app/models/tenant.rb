class Tenant < ApplicationRecord
  include RotatingCursor

  self.table_name = "tenants"

  devise :database_authenticatable, :rememberable, :validatable,
         :lockable, :timeoutable, :trackable

  has_many :calls,    dependent: :restrict_with_error
  has_many :contacts, dependent: :restrict_with_error
  has_many :rules,    dependent: :restrict_with_error
  has_many :audit_logs, dependent: :nullify
  has_many :acted_audit_logs, class_name: "AuditLog", foreign_key: :actor_id, dependent: :nullify

  has_many :phrases, dependent: :destroy   # tenant-owned phrases
  has_many :tags,    dependent: :destroy
  has_many :tenant_phrases, dependent: :destroy
  has_many :default_pool_phrases, through: :tenant_phrases, source: :phrase

  ALLOWED_VOICES    = GreetingCatalog::ALLOWED_VOICES
  SPAM_RESPONSE_MODES = %w[silent polite_disclose time_waster].freeze
  USERNAME_FORMAT   = /\A[a-z0-9._-]+\z/i
  E164_FORMAT       = /\A\+?[0-9]{6,15}\z/
  SLUG_FORMAT       = /\A[a-z0-9._-]+\z/

  validates :slug,
            presence: true,
            uniqueness: { case_sensitive: false },
            format: { with: SLUG_FORMAT, message: "must be lowercase letters, digits, dot, hyphen, underscore" }

  validates :mobile_number,
            uniqueness: { allow_nil: true },
            format: { with: E164_FORMAT, allow_nil: true, message: "must be E.164 (+digits)" }

  validates :dedicated_number,
            uniqueness: { allow_nil: true },
            format: { with: E164_FORMAT, allow_nil: true, message: "must be E.164 (+digits)" }

  validates :forward_back_number,
            format: { with: E164_FORMAT, allow_blank: true, message: "must be E.164 (+digits)" }

  validates :railsdav_username,
            format: { with: USERNAME_FORMAT, allow_blank: true, message: "letters, digits, dot, hyphen, underscore only" }

  validates :greeting_voice,    inclusion: { in: ALLOWED_VOICES }, allow_blank: true
  validates :greeting_language, format: { with: /\A[a-z]{2}-[A-Z]{2}\z/, allow_blank: true }
  validate  :voice_rotation_voices_known
  validate  :greeting_variant_in_catalog
  validate  :greeting_tone_in_catalog

  validates :spam_sensitivity,
            numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0, allow_nil: true }
  validates :max_recording_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 5, less_than_or_equal_to: 600, allow_nil: true }
  validates :max_calls_per_caller_per_day,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000, allow_nil: true }
  validates :auto_blacklist_threshold,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100, allow_nil: true }
  validates :auto_blacklist_window_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 365, allow_nil: true }

  validates :spam_response_mode, inclusion: { in: SPAM_RESPONSE_MODES }
  validates :spam_troll_max_seconds,
            numericality: { only_integer: true, greater_than_or_equal_to: 30, less_than_or_equal_to: 300 }

  validate :screening_speech_timeout_valid
  validate :only_one_default_tenant
  validate :voice_clone_active_requires_consent_and_sample
  validate :tod_hours_in_range_and_monotonic
  validate :time_zone_is_resolvable

  before_validation :default_forward_back_to_mobile, on: :create

  scope :active, -> { where(active: true) }

  def self.default
    find_by(default_tenant: true)
  end

  def default?
    default_tenant
  end

  def super_admin?
    admin
  end

  def display_name
    name.presence || slug.presence || email
  end

  # Per-tenant cloned voice lives in storage/greetings/<slug>/_t<id>/<tone>.wav.
  # The "_t" prefix can never collide with a Kokoro voice slug (Kokoro
  # voices match [a-z]{2}_[a-z]+) so the path is unambiguous.
  def cloned_voice_dir
    "_t#{id}"
  end

  def voice_clone_ready?
    voice_clone_active? && voice_clone_rendered_at.present?
  end

  def voice_rotation_voice_list
    voice_rotation_voices.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def voice_rotation_ready?
    voice_rotation_enabled? && voice_rotation_voice_list.any?
  end

  # Atomically pick the next voice from the rotation list and advance the
  # cursor (see RotatingCursor).
  def next_rotated_voice!
    advance_rotation!(voice_rotation_voice_list, column: :voice_rotation_index)
  end

  def phrase_rotation_variant_list
    phrase_rotation_variants.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def phrase_rotation_ready?
    phrase_rotation_enabled? && phrase_rotation_variant_list.any?
  end

  def next_rotated_variant!
    advance_rotation!(phrase_rotation_variant_list, column: :phrase_rotation_index)
  end

  private

  # voice_rotation_voices is a free-text comma-separated column edited from
  # the profile/tenant forms. Every entry must be a known Kokoro/Chatterbox
  # voice or this tenant's own cloned-voice dir (_t<own id>). This blocks a
  # tenant from injecting a path-traversal component (e.g. "../../etc") that
  # would flow into GreetingsStorage.path_for, and from referencing another
  # tenant's cloned voice (_t<other id>).
  CLONED_VOICE_FORMAT = /\A_t\d+\z/

  def voice_rotation_voices_known
    return if voice_rotation_voices.blank?
    own_clone = cloned_voice_dir if persisted?
    bad = voice_rotation_voice_list.reject do |v|
      ALLOWED_VOICES.include?(v) || (v.match?(CLONED_VOICE_FORMAT) && v == own_clone)
    end
    return if bad.empty?
    errors.add(:voice_rotation_voices, "contains unknown or non-owned voices: #{bad.join(', ')}")
  end

  def voice_clone_active_requires_consent_and_sample
    return unless voice_clone_active?
    if voice_clone_consent_at.blank?
      errors.add(:voice_clone_active, "requires consent before activation")
    end
    if voice_sample_path.blank?
      errors.add(:voice_clone_active, "requires a voice sample to be uploaded")
    end
  end

  def default_forward_back_to_mobile
    return unless forward_back_number.blank?
    return unless mobile_number.present? && mobile_number.match?(E164_FORMAT)
    self.forward_back_number = mobile_number
  end

  def greeting_variant_in_catalog
    return if greeting_variant.blank?
    # Accept any phrase visible to this tenant (shared system rows + own).
    visible = Phrase.where(slug: greeting_variant.to_s)
                    .where("tenant_id IS NULL OR tenant_id = ?", id)
    return if visible.exists?
    errors.add(:greeting_variant, "must reference an existing phrase")
  end

  def greeting_tone_in_catalog
    return if greeting_tone.blank?
    return if GreetingCatalog::TONE_SLUGS.include?(greeting_tone.to_s)
    errors.add(:greeting_tone, "must be one of #{GreetingCatalog::TONE_SLUGS.join(', ')}")
  end

  def screening_speech_timeout_valid
    s = screening_speech_timeout.to_s
    return if s.blank? || s == "auto"
    i = Integer(s, exception: false)
    return if i&.between?(1, 60)
    errors.add(:screening_speech_timeout, "must be 'auto' or an integer between 1 and 60")
  end

  def only_one_default_tenant
    return unless default_tenant?
    other = self.class.where(default_tenant: true).where.not(id: id)
    errors.add(:default_tenant, "another tenant is already the default") if other.exists?
  end

  def time_zone_is_resolvable
    return if time_zone.blank?
    return if Time.find_zone(time_zone)
    errors.add(:time_zone, "is not a recognized time zone")
  end

  def tod_hours_in_range_and_monotonic
    hours = [ tod_morning_hour, tod_afternoon_hour, tod_evening_hour, tod_night_hour ]
    return if hours.all?(&:nil?)
    unless hours.all? { |h| h.is_a?(Integer) && (0..23).cover?(h) }
      errors.add(:base, "time-of-day hours must be integers in 0..23")
      return
    end
    sorted = hours.sort
    if sorted != hours
      errors.add(:base, "time-of-day hours must be in order: morning < afternoon < evening < night")
    end
    if sorted.uniq.size != sorted.size
      errors.add(:base, "time-of-day hours must be distinct")
    end
  end
end
