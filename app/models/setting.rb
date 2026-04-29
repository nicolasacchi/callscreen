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
    "auto_delete_days" => "30",
    "auto_delete_transcripts_days" => "30",
    "transcription_engine" => "Google"
  }.freeze

  ALLOWED_TRANSCRIPTION_ENGINES = %w[Google Telnyx Azure Deepgram].freeze

  VALIDATORS = {
    "spam_sensitivity" => :validate_sensitivity,
    "max_recording_seconds" => :validate_recording_seconds,
    "auto_delete_days" => :validate_delete_days,
    "auto_delete_transcripts_days" => :validate_delete_days,
    "greeting_language" => :validate_language,
    "greeting_voice" => :validate_voice,
    "screening_speech_timeout" => :validate_speech_timeout,
    "greeting_text" => :validate_text,
    "voicemail_prompt" => :validate_text,
    "transcription_engine" => :validate_transcription_engine
  }.freeze

  class InvalidValue < ArgumentError; end

  def self.get(key)
    find_by(key: key.to_s)&.value || DEFAULTS[key.to_s]
  end

  def self.set(key, value)
    key_s = key.to_s
    if (validator = VALIDATORS[key_s]) && !send(validator, value)
      raise InvalidValue, "Invalid value for #{key_s}"
    end
    setting = find_or_initialize_by(key: key_s)
    setting.update!(value: value.to_s)
  end

  def self.all_with_defaults
    stored = all.index_by(&:key)
    DEFAULTS.map do |key, default|
      stored[key] || new(key: key, value: default, description: key.humanize)
    end
  end

  def self.validate_sensitivity(v)
    f = Float(v.to_s, exception: false)
    !f.nil? && f.between?(0.0, 1.0)
  end

  def self.validate_recording_seconds(v)
    i = Integer(v.to_s, exception: false)
    !i.nil? && i.between?(5, 600)
  end

  def self.validate_delete_days(v)
    i = Integer(v.to_s, exception: false)
    !i.nil? && i.between?(1, 3650)
  end

  def self.validate_language(v)
    v.to_s.match?(/\A[a-z]{2}-[A-Z]{2}\z/)
  end

  def self.validate_voice(v)
    v.to_s.match?(/\A[A-Za-z][A-Za-z0-9._-]{0,63}\z/)
  end

  def self.validate_speech_timeout(v)
    s = v.to_s
    return true if s == "auto"
    i = Integer(s, exception: false)
    !i.nil? && i.between?(1, 60)
  end

  def self.validate_text(v)
    s = v.to_s
    s.length.between?(1, 500)
  end

  def self.validate_transcription_engine(v)
    ALLOWED_TRANSCRIPTION_ENGINES.include?(v.to_s)
  end
end
