module Admin
  class ContactsController < BaseController
    def index
      scope = Contact.order(last_called_at: :desc)
      if params[:q].present?
        like = ActiveRecord::Base.sanitize_sql_like(params[:q].to_s)
        scope = scope.where("phone LIKE ? OR name LIKE ?", "%#{like}%", "%#{like}%")
      end
      @contacts = paginate(scope)
    end

    def show
      @contact = Contact.find(params[:id])
      @calls = @contact.calls.recent.limit(20)
    end

    def new
      @contact = Contact.new
    end

    def create
      @contact = Contact.new(contact_params)
      @contact.phone = PhoneNumberNormalizer.normalize(@contact.phone)
      if @contact.save
        redirect_to admin_contact_path(@contact), notice: "Contact created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @contact = Contact.find(params[:id])
    end

    def update
      @contact = Contact.find(params[:id])
      if @contact.update(contact_params)
        redirect_to admin_contact_path(@contact), notice: "Contact updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      contact = Contact.find(params[:id])
      contact.destroy
      redirect_to admin_contacts_path, notice: "Contact deleted."
    end

    private

    def contact_params
      params.require(:contact).permit(:phone, :name, :whitelisted, :blacklisted, :notes)
    end
  end
end
