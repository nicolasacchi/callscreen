module Admin
  class ContactsController < BaseController
    def index
      scope = viewing_tenant.contacts.order(last_called_at: :desc)
      if params[:q].present?
        like = ActiveRecord::Base.sanitize_sql_like(params[:q].to_s, "!")
        scope = scope.where("phone LIKE ? ESCAPE '!' OR name LIKE ? ESCAPE '!'", "%#{like}%", "%#{like}%")
      end
      @contacts = paginate(scope)
    end

    def show
      @contact = viewing_tenant.contacts.find(params[:id])
      @calls   = @contact.calls.recent.limit(20)
    end

    def new
      @contact = viewing_tenant.contacts.new
    end

    def create
      @contact = viewing_tenant.contacts.new(contact_params)
      @contact.phone = PhoneNumberNormalizer.normalize(@contact.phone)
      if @contact.save
        redirect_to admin_contact_path(@contact), notice: "Contact created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @contact = viewing_tenant.contacts.find(params[:id])
    end

    def update
      @contact = viewing_tenant.contacts.find(params[:id])
      assign_phrase_ids(@contact)
      assign_tag_names(@contact)
      if @contact.update(contact_params)
        redirect_to admin_contact_path(@contact), notice: "Contact updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      contact = viewing_tenant.contacts.find(params[:id])
      contact.destroy
      redirect_to admin_contacts_path, notice: "Contact deleted."
    end

    private

    def contact_params
      params.require(:contact).permit(:phone, :name, :whitelisted, :blacklisted, :notes, :language)
    end

    def assign_phrase_ids(contact)
      return unless params.dig(:contact, :phrase_ids)
      ids = Array(params[:contact][:phrase_ids]).map(&:to_i).reject(&:zero?)
      visible = Phrase.visible_to(viewing_tenant).where(id: ids).pluck(:id)
      contact.phrase_ids = visible
      # Reset cursor when the pool changes so rotation restarts cleanly.
      contact.update_columns(phrase_rotation_index: 0) if contact.persisted?
    end

    def assign_tag_names(contact)
      return unless params.dig(:contact, :tag_names)
      Tag.assign_csv(contact, params[:contact][:tag_names], tenant: viewing_tenant)
    end
  end
end
