module Admin
  class CallsController < BaseController
    def index
      scope = Call.recent.includes(:contact)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where("from_number LIKE ?", "%#{params[:q]}%") if params[:q].present?
      @calls = paginate(scope)
    end

    def show
      @call = Call.find(params[:id])
    end

    def mark_spam
      call = Call.find(params[:id])
      call.update!(status: :spam)
      redirect_to admin_call_path(call), notice: "Marked as spam."
    end

    def mark_legit
      call = Call.find(params[:id])
      call.update!(status: :legit)
      redirect_to admin_call_path(call), notice: "Marked as legit."
    end

    def block_number
      call = Call.find(params[:id])
      contact = Contact.find_or_create_by!(phone: call.from_number)
      contact.update!(blacklisted: true)
      call.update!(status: :spam)
      redirect_to admin_call_path(call), notice: "Number blocked."
    end
  end
end
