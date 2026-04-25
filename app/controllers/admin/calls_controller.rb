module Admin
  class CallsController < BaseController
    def index
      scope = Call.recent.includes(:contact)
      scope = scope.where(status: params[:status]) if params[:status].present?
      if params[:q].present?
        like = ActiveRecord::Base.sanitize_sql_like(params[:q].to_s, "!")
        scope = scope.where("from_number LIKE ? ESCAPE '!'", "%#{like}%")
      end
      @calls = paginate(scope)
    end

    def show
      @call = Call.find(params[:id])
    end

    def mark_spam
      call = Call.find(params[:id])
      call.update!(status: :spam)
      audit("mark_spam", call, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Marked as spam."
    end

    def mark_legit
      call = Call.find(params[:id])
      call.update!(status: :legit)
      audit("mark_legit", call, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Marked as legit."
    end

    def block_number
      call = Call.find(params[:id])
      contact = Contact.find_or_create_by!(phone: call.from_number)
      contact.update!(blacklisted: true)
      call.update!(status: :spam)
      audit("block_number", call, contact_id: contact.id, from: call.from_number)
      redirect_to admin_call_path(call), notice: "Number blocked."
    end

    private

    def audit(action_name, subject, metadata = {})
      AuditLog.create!(
        admin_user: current_admin_user,
        action: action_name,
        subject_type: subject.class.name,
        subject_id: subject.id,
        metadata: metadata
      )
    end
  end
end
