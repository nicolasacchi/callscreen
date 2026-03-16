class Rule < ApplicationRecord
  enum :rule_type, { prefix: 0, keyword: 1, regex: 2 }
  enum :action, { allow: 0, block: 1 }, prefix: :action

  validates :value, presence: true
  validates :rule_type, presence: true
  validates :action, presence: true

  scope :active, -> { where(active: true).order(priority: :desc) }

  def matches_number?(phone_number)
    return false unless phone_number.present?

    case rule_type
    when "prefix"
      phone_number.start_with?(value)
    when "regex"
      phone_number.match?(Regexp.new(value))
    else
      false
    end
  end

  def matches_transcript?(transcript)
    return false unless transcript.present? && keyword?
    transcript.downcase.include?(value.downcase)
  end
end
