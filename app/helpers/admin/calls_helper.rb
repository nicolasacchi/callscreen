module Admin
  module CallsHelper
    ALLOWED_CLASSIFICATIONS = %w[spam legit uncertain].freeze

    def classification_badge_class(classification)
      key = ALLOWED_CLASSIFICATIONS.include?(classification.to_s) ? classification : "unknown"
      "badge-#{key}"
    end

    def classification_display(classification)
      ALLOWED_CLASSIFICATIONS.include?(classification.to_s) ? classification : "unknown"
    end
  end
end
