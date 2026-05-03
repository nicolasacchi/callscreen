# Runs after the screening recording is saved by Telnyx. Downloads the
# audio, transcribes with Whisper, classifies the transcript, and decides
# the call's final disposition. The recording IS the voicemail — there's
# no separate voicemail prompt after screening.
class ScreeningJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound
  retry_on Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error,
           wait: :polynomially_longer, attempts: 3

  def perform(call_id)
    call = Call.find(call_id)
    tenant = call.tenant

    local_path = RecordingDownloader.fetch(call)
    transcript = WhisperClient.new(local_path).transcribe.to_s.strip

    call.update!(
      recording_local_path: local_path,
      screening_transcript: transcript,
      voicemail_transcript: transcript
    )

    if transcript.blank?
      finalize(call, status: :unknown)
      return
    end

    # Keyword-block rules short-circuit the LLM.
    keyword_rule = tenant.rules.active.keyword.find { |r| r.matches_transcript?(transcript) }
    if keyword_rule&.action_block?
      keyword_rule.increment!(:hit_count)
      classification = {
        "classification" => "spam",
        "confidence" => 1.0,
        "reason" => "Keyword rule: #{keyword_rule.value}"
      }
      finalize(call, status: :spam, ai_classification: classification)
      auto_blacklist_if_pattern_match(call)
      return
    end

    sensitivity = tenant.spam_sensitivity || Setting.get("spam_sensitivity").to_f
    result = SpamClassifier.new(transcript, from_number: call.from_number,
                                sensitivity: sensitivity).classify

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        finalize(call, status: :spam, ai_classification: result)
        auto_blacklist_if_pattern_match(call)
      else
        finalize(call, status: :uncertain, ai_classification: result)
      end
    when "legit"
      finalize(call, status: :legit, ai_classification: result)
    else
      finalize(call, status: :uncertain, ai_classification: result)
    end
  rescue => e
    Rails.logger.error("ScreeningJob failed for call #{call_id}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    Call.find_by(id: call_id)&.update!(status: :failed, flow_state: "done")
    raise
  end

  private

  def finalize(call, status:, ai_classification: nil)
    attrs = { status: status, flow_state: "done" }
    attrs[:ai_classification] = ai_classification if ai_classification
    call.update!(attrs)
    NotifyJob.perform_later(call.id)
    # If the leg is still up (Telnyx keeps it open until we hangup),
    # close it. The hangup is best-effort: a 422 "Call has already
    # ended" is fine and gets logged at warn level by CallControlClient.
    CallControlClient.new.hangup(call.call_control_id) if call.call_control_id.present?
  end

  def auto_blacklist_if_pattern_match(call)
    tenant = call.tenant
    contact = call.contact
    return unless contact
    return if contact.blacklisted? || contact.whitelisted?

    threshold = (tenant.auto_blacklist_threshold || 3).to_i
    window    = (tenant.auto_blacklist_window_days || 7).to_i
    return if threshold <= 0 || window <= 0

    count = contact.recent_spam_count(within: window.days)
    return if count < threshold

    contact.update!(blacklisted: true)
    AuditLog.create!(
      actor: nil, tenant: tenant, action: "auto_blacklist",
      subject_type: "Contact", subject_id: contact.id,
      metadata: {
        from: call.from_number, spam_count: count,
        window_days: window, threshold: threshold
      }
    )
  end
end
