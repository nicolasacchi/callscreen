class Tenant < ApplicationRecord
  self.table_name = "tenants"

  devise :database_authenticatable, :rememberable, :validatable,
         :lockable, :timeoutable, :trackable

  has_many :calls,    dependent: :restrict_with_error
  has_many :contacts, dependent: :restrict_with_error
  has_many :rules,    dependent: :restrict_with_error
  has_many :audit_logs, dependent: :nullify
  has_many :acted_audit_logs, class_name: "AuditLog", foreign_key: :actor_id, dependent: :nullify

  ALLOWED_VOICES    = %w[if_sara im_nicola af_heart am_michael alice man woman].freeze
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

  validate :screening_speech_timeout_valid
  validate :only_one_default_tenant

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

  private

  def default_forward_back_to_mobile
    return unless forward_back_number.blank?
    return unless mobile_number.present? && mobile_number.match?(E164_FORMAT)
    self.forward_back_number = mobile_number
  end

  def greeting_variant_in_catalog
    return if greeting_variant.blank?
    return if GreetingCatalog::SLUGS.include?(greeting_variant.to_s)
    errors.add(:greeting_variant, "must be one of #{GreetingCatalog::SLUGS.join(', ')}")
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
end
