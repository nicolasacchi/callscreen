module Admin
  class CallsController < BaseController
    def index
      scope = viewing_tenant.calls.recent.includes(:contact)
      scope = scope.where(status: params[:status]) if params[:status].present?
      if params[:q].present?
        like = ActiveRecord::Base.sanitize_sql_like(params[:q].to_s, "!")
        scope = scope.where("from_number LIKE ? ESCAPE '!'", "%#{like}%")
      end
      @calls = paginate(scope)
    end

    def show
      @call = viewing_tenant.calls.find(params[:id])
    end

    def mark_spam
      call = viewing_tenant.calls.find(params[:id])
      call.update!(status: :spam)
      audit("mark_spam", call, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Marked as spam."
    end

    def mark_legit
      call = viewing_tenant.calls.find(params[:id])
      call.update!(status: :legit)
      audit("mark_legit", call, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Marked as legit."
    end

    def block_number
      call = viewing_tenant.calls.find(params[:id])
      contact = viewing_tenant.contacts.find_or_create_by!(phone: call.from_number)
      contact.update!(blacklisted: true, whitelisted: false)
      call.update!(status: :spam)
      audit("block_number", call, contact_id: contact.id, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Number blocked."
    end

    # Mark this caller as trusted: future calls from this number bypass the
    # screening flow entirely and are dialed straight to the tenant's
    # forward_back_number.
    def whitelist_number
      call = viewing_tenant.calls.find(params[:id])
      contact = viewing_tenant.contacts.find_or_create_by!(phone: call.from_number)
      contact.update!(whitelisted: true, blacklisted: false)
      audit("whitelist_number", call, contact_id: contact.id, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Numero #{call.from_number} aggiunto ai contatti fidati."
    end

    private

    def audit(action_name, subject, metadata = {})
      AuditLog.create!(
        actor: current_tenant,
        tenant: viewing_tenant,
        action: action_name,
        subject_type: subject.class.name,
        subject_id: subject.id,
        metadata: metadata
      )
    end
  end
end
