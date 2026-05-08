module Admin
  # Lightweight CRUD over Tag rows. Auto-creation happens in PhrasesController
  # / Contacts edit form via chip-input; this controller is for cleanup
  # (rename/delete/inspect). Tenant-scoped: each tenant sees only their
  # own tags.
  class TagsController < BaseController
    def index
      @tags = Tag.for_tenant(viewing_tenant).order(:name)
    end

    def destroy
      tag = viewing_tenant.tags.find(params[:id])
      tag.destroy
      redirect_to admin_tags_path, notice: "Tag '#{tag.name}' removed."
    end
  end
end
