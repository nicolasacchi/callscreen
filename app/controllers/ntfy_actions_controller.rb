# Endpoints called from ntfy notification action buttons. The notification
# embeds a per-call signed token (see NtfyActionToken); tapping a button
# fires a POST here. No Devise session — the token is the only credential.
class NtfyActionsController < ApplicationController
  protect_from_forgery with: :null_session

  ACTIVE_SPAM_FLOW_STATES = %w[spam_disclose_playing troll_playing].freeze

  def whitelist; perform!(:whitelist); end
  def mark_spam; perform!(:mark_spam); end
  def report_spam_globally; perform!(:report_spam_globally); end

  private

  def perform!(action)
    payload = NtfyActionToken.decode(params[:t])
    return head :unauthorized if payload.empty?
    return head :unauthorized unless payload[:call_id].to_i == params[:call_id].to_i
    return head :unauthorized unless payload[:action].to_s == action.to_s

    call = Call.find_by(id: payload[:call_id])
    return head :not_found unless call

    case action
    when :whitelist
      contact = call.contact || call.tenant.contacts.find_or_create_by!(phone: call.from_number)
      contact.update!(whitelisted: true, blacklisted: false)
      audit!(call, "whitelist_number", contact_id: contact.id)
      # Propagate the trust decision UP to railsdav's central book (best-effort,
      # background) so the shared policy learns it too — mirrors the spam-UP path.
      RailsdavAllowJob.maybe_enqueue(call)
      # If the operator whitelists while a polite_disclose / troll
      # response is still mid-flight, abort the active call — otherwise
      # the spammer keeps getting trolled even though we've decided
      # they're legit.
      abort_active_spam_response(call)
    when :mark_spam
      # Persist the spam signal against a Contact (mirror :whitelist) so the
      # learning loop + per-caller history pick it up (P2-2).
      contact = call.contact || call.tenant.contacts.find_or_create_by!(phone: call.from_number)
      call.update!(status: :spam)
      call.update!(contact: contact) if call.contact_id.nil?
      audit!(call, "mark_spam", contact_id: contact.id)
      ReportSpamGloballyJob.maybe_enqueue(call) # opt-in cross-tenant share (P2-7)
    when :report_spam_globally
      result = RailsdavSpamReporter.report(
        call.from_number,
        source:   "ntfy_report",
        username: call.tenant&.railsdav_username,
        notes:    call.spam_evidence_note # the AI's WHY enriches the shared DB
      )
      audit!(call, "report_spam_globally",
             railsdav_ack: result[:ok] == true,
             railsdav_error: result[:error])
      call.update!(status: :spam) unless call.spam?
      # Surface failures to the operator's phone — ntfy treats non-200
      # as an error and shows it in the notification.
      return head :bad_gateway unless result[:ok]
    end

    head :ok
  end

  def abort_active_spam_response(call)
    return unless ACTIVE_SPAM_FLOW_STATES.include?(call.flow_state)
    return if call.call_control_id.blank?
    cc_client.hangup(call.call_control_id)
    call.update!(flow_state: "done")
  end

  def cc_client
    @cc_client ||= CallControlClient.new
  end

  def audit!(call, action_name, **metadata)
    AuditLog.record(action: action_name, subject: call, tenant: call.tenant,
                    **metadata, source: "ntfy", from: call.from_number)
  end
end
