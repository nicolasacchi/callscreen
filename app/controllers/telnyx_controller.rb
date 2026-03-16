class TelnyxController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_webhook_token

  def voice
    from = PhoneNumberNormalizer.normalize(params[:From])
    to = params[:To]
    call_sid = params[:CallSid]

    contact = Contact.find_or_initialize_by(phone: from)
    if contact.new_record?
      contact.save!
    else
      contact.increment!(:calls_count)
      contact.update!(last_called_at: Time.current)
    end

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
      render_texml TexmlBuilder.hangup(message: "Arrivederci.")
      return
    end

    # Check keyword rules against transcript
    keyword_rule = Rule.active.keyword.find { |r| r.matches_transcript?(speech_result) }
    if keyword_rule
      keyword_rule.increment!(:hit_count)
      if keyword_rule.action_block?
        call.update!(status: :spam, ai_classification: { "classification" => "spam", "confidence" => 1.0, "reason" => "Keyword rule: #{keyword_rule.value}" })
        NotifyJob.perform_later(call.id)
        render_texml TexmlBuilder.hangup(message: "Grazie per aver chiamato. Arrivederci.")
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
        render_texml TexmlBuilder.hangup(message: "Grazie per aver chiamato. Arrivederci.")
      else
        # Below sensitivity threshold — treat as uncertain
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

  def verify_webhook_token
    token = params[:token]
    expected = ENV.fetch("WEBHOOK_TOKEN", "")
    unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)
      head :unauthorized
    end
  end

  def webhook_url(action)
    app_domain = ENV.fetch("APP_DOMAIN", "https://phone.example.com")
    token = ENV.fetch("WEBHOOK_TOKEN", "")
    "#{app_domain}/telnyx/#{action}?token=#{token}"
  end

  def render_texml(xml)
    render plain: xml, content_type: "text/xml"
  end
end
