# Endpoints called from ntfy notification action buttons. The notification
# embeds a per-call signed token (see NtfyActionToken); tapping a button
# fires a POST here. No Devise session — the token is the only credential.
class NtfyActionsController < ApplicationController
  protect_from_forgery with: :null_session

  def whitelist; perform!(:whitelist); end
  def mark_spam; perform!(:mark_spam); end
  def mark_legit; perform!(:mark_legit); end

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
    when :mark_spam
      call.update!(status: :spam)
      audit!(call, "mark_spam")
    when :mark_legit
      call.update!(status: :legit)
      audit!(call, "mark_legit")
    end

    head :ok
  end

  def audit!(call, action_name, **metadata)
    AuditLog.create!(
      actor: nil,
      tenant: call.tenant,
      action: action_name,
      subject_type: call.class.name,
      subject_id: call.id,
      metadata: metadata.merge(source: "ntfy", from: call.from_number)
    )
  end
end
