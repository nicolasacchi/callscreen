class TelnyxController < ApplicationController
  # Telnyx call_control_id format is base64url + ":" version prefix, up to ~150 chars.
  # Conservatively bound to filename-safe chars + 256 length; no "/" so path traversal
  # is impossible regardless of what's downstream.
  CALL_SID_FORMAT = /\A[A-Za-z0-9_:=\-]{1,256}\z/

  skip_before_action :verify_authenticity_token
  before_action :verify_telnyx_request
  before_action :verify_call_sid_format, only: [ :voice ]

  def voice
    call_sid = params[:CallSid].to_s
    from = PhoneNumberNormalizer.normalize(params[:From])
    to = params[:To]

    contact = Contact.find_or_initialize_by(phone: from)
    contact.last_called_at = Time.current
    contact.save!

    call = Call.create!(
      call_sid: call_sid,
      from_number: from,
      to_number: to,
      status: :initiated,
      contact: contact
    )

    if contact.blacklisted?
      call.update!(status: :spam)
      render_texml TexmlBuilder.reject
      return
    end

    if contact.whitelisted?
      call.update!(status: :legit)
      forward_number = ENV["FORWARD_NUMBER"]
      if forward_number.present?
        render_texml TexmlBuilder.forward_call(forward_number)
      else
        call.update!(status: :recording)
        render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
      end
      return
    end

    # Check rules against phone number
    rule_match = Rule.active.find { |r| r.matches_number?(from) }
    if rule_match
      rule_match.increment!(:hit_count)
      if rule_match.action_block?
        call.update!(status: :spam)
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.reject
        return
      elsif rule_match.action_allow?
        call.update!(status: :legit)
        forward_number = ENV["FORWARD_NUMBER"]
        if forward_number.present?
          render_texml TexmlBuilder.forward_call(forward_number)
        else
          call.update!(status: :recording)
          render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
        end
        return
      end
    end

    # Default: screen the call
    call.update!(status: :screening)
    render_texml TexmlBuilder.greeting_and_gather(action_url: webhook_url(:screen))
  end

  def screen
    call_sid = params[:CallSid]
    speech_result = params[:SpeechResult]
    call = Call.find_by!(call_sid: call_sid)

    call.update!(screening_transcript: speech_result)

    if speech_result.blank?
      call.update!(status: :spam)
      NotifyJob.perform_later(call.id)
      render_texml TexmlBuilder.hangup(phrase: "goodbye_short")
      return
    end

    # Check keyword rules against transcript
    keyword_rule = Rule.active.keyword.find { |r| r.matches_transcript?(speech_result) }
    if keyword_rule
      keyword_rule.increment!(:hit_count)
      if keyword_rule.action_block?
        call.update!(status: :spam, ai_classification: { "classification" => "spam", "confidence" => 1.0, "reason" => "Keyword rule: #{keyword_rule.value}" })
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.hangup(phrase: "goodbye_spam")
        return
      end
    end

    # AI classification
    result = SpamClassifier.new(speech_result, from_number: call.from_number).classify
    call.update!(ai_classification: result)

    sensitivity = Setting.get("spam_sensitivity").to_f

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        call.update!(status: :spam)
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.hangup(phrase: "goodbye_spam")
      else
        # Low-confidence spam → ask one clarifying question before voicemail.
        call.update!(status: :uncertain)
        render_texml TexmlBuilder.clarify_and_gather(action_url: webhook_url(:clarify))
      end
    when "legit"
      call.update!(status: :legit)
      NotifyJob.perform_later(call.id)
      render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
    else
      # Explicit uncertain → ask one clarifying question.
      call.update!(status: :uncertain)
      render_texml TexmlBuilder.clarify_and_gather(action_url: webhook_url(:clarify))
    end
  end

  # Second-turn handler invoked after clarify_and_gather. We re-classify
  # using both the original screening transcript and the caller's response
  # to the clarification prompt, then route definitively.
  def clarify
    call_sid = params[:CallSid]
    speech_result = params[:SpeechResult]
    call = Call.find_by!(call_sid: call_sid)

    combined = "#{call.screening_transcript}\n[Clarification]: #{speech_result}".strip
    call.update!(screening_transcript: combined)

    if speech_result.blank?
      call.update!(status: :spam)
      NotifyJob.perform_later(call.id)
      render_texml TexmlBuilder.hangup(phrase: "goodbye_short")
      return
    end

    result = SpamClassifier.new(combined, from_number: call.from_number).classify
    call.update!(ai_classification: result)
    sensitivity = Setting.get("spam_sensitivity").to_f

    case result["classification"]
    when "spam"
      if result["confidence"].to_f >= sensitivity
        call.update!(status: :spam)
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.hangup(phrase: "goodbye_spam")
      else
        call.update!(status: :uncertain)
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
      end
    when "legit"
      call.update!(status: :legit)
      NotifyJob.perform_later(call.id)
      render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
    else
      call.update!(status: :uncertain)
      NotifyJob.perform_later(call.id)
      render_texml TexmlBuilder.record_voicemail(action_url: webhook_url(:recording))
    end
  end

  def recording
    call_sid = params[:CallSid]
    recording_url = params[:RecordingUrl]
    recording_duration = params[:RecordingDuration]

    call = Call.find_by!(call_sid: call_sid)
    call.update!(
      recording_url: recording_url,
      duration_seconds: recording_duration.to_i,
      status: :completed
    )

    TranscribeRecordingJob.perform_later(call.id)

    render_texml TexmlBuilder.hangup
  end

  def status
    call_sid = params[:CallSid]
    call = Call.find_by(call_sid: call_sid)
    return head :ok unless call

    call_duration = params[:CallDuration]
    call.update!(duration_seconds: call_duration.to_i) if call_duration.present?

    if call.contact.present?
      call.contact.update!(last_called_at: Time.current)
    end

    head :ok
  end

  private

  def verify_telnyx_request
    return if signature_valid?
    return if fallback_token_valid?
    head :unauthorized
  end

  def signature_valid?
    sig = request.headers["Telnyx-Signature-Ed25519"]
    ts  = request.headers["Telnyx-Timestamp"]
    return false if sig.blank? || ts.blank?

    request.body.rewind
    payload = request.body.read

    TelnyxSignatureVerifier.new.verify(payload: payload, signature: sig, timestamp: ts)
  end

  def fallback_token_valid?
    return false unless fallback_enabled?
    expected = ENV.fetch("WEBHOOK_TOKEN", "")
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)
  end

  def fallback_enabled?
    ENV["WEBHOOK_TOKEN"].present? && ENV["WEBHOOK_TOKEN_FALLBACK"] != "0"
  end

  def verify_call_sid_format
    head :bad_request unless params[:CallSid].to_s.match?(CALL_SID_FORMAT)
  end

  def webhook_url(action)
    app_domain = ENV.fetch("APP_DOMAIN", "https://phone.example.com")
    base = "#{app_domain}/telnyx/#{action}"
    if fallback_enabled?
      "#{base}?token=#{ENV.fetch('WEBHOOK_TOKEN', '')}"
    else
      base
    end
  end

  def render_texml(xml)
    render plain: xml, content_type: "text/xml"
  end
end
