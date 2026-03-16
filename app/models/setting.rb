class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  DEFAULTS = {
    "greeting_text" => "Buongiorno. Questa chiamata potrebbe essere registrata. Chi parla e qual e' il motivo della chiamata?",
    "greeting_language" => "it-IT",
    "greeting_voice" => "alice",
    "voicemail_prompt" => "Per favore, lasci un messaggio dopo il segnale acustico.",
    "spam_sensitivity" => "0.5",
    "max_recording_seconds" => "120",
    "screening_speech_timeout" => "auto",
    "auto_delete_days" => "30"
  }.freeze

  def self.get(key)
    find_by(key: key.to_s)&.value || DEFAULTS[key.to_s]
  end

  def self.set(key, value)
    setting = find_or_initialize_by(key: key.to_s)
    setting.update!(value: value.to_s)
  end

  def self.all_with_defaults
    stored = all.index_by(&:key)
    DEFAULTS.map do |key, default|
      stored[key] || new(key: key, value: default, description: key.humanize)
    end
  end
end
