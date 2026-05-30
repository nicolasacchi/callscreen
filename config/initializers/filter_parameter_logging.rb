# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :From, :To, :CallSid, :SpeechResult, :RecordingUrl,
  :phone, :transcript, :screening_transcript, :voicemail_transcript, :name,
  # The ntfy-action signed token rides in the one-char :t param (a 48h
  # state-changing credential). Filter it with an ANCHORED regexp — a bare :t
  # symbol is a substring match that would also redact `to`, `tenant`,
  # `status`, etc. from every log line (SEC-1). :synthetic_token / :token are
  # already covered by the :token match above.
  /\At\z/
]
