class Rule < ApplicationRecord
  REGEX_VALIDATION_TIMEOUT = 0.05
  REGEX_VALIDATION_INPUT = ("a" * 100) + "X"

  enum :rule_type, { prefix: 0, keyword: 1, regex: 2 }
  enum :action, { allow: 0, block: 1 }, prefix: :action

  validates :value, presence: true
  validates :rule_type, presence: true
  validates :action, presence: true
  validate :regex_value_is_safe

  scope :active, -> { where(active: true).order(priority: :desc) }

  def matches_number?(phone_number)
    return false unless phone_number.present?

    case rule_type
    when "prefix"
      phone_number.start_with?(value)
    when "regex"
      phone_number.match?(Regexp.new(value, timeout: 1.0))
    else
      false
    end
  end

  def matches_transcript?(transcript)
    return false unless transcript.present? && keyword?
    transcript.downcase.include?(value.downcase)
  end

  private

  def regex_value_is_safe
    return unless rule_type == "regex" && value.present?

    re = Regexp.new(value, timeout: REGEX_VALIDATION_TIMEOUT)
    re.match?(REGEX_VALIDATION_INPUT)
  rescue RegexpError => e
    errors.add(:value, "is not a valid regex: #{e.message}")
  rescue Regexp::TimeoutError
    errors.add(:value, "regex took too long to evaluate (possible ReDoS pattern)")
  end
end
