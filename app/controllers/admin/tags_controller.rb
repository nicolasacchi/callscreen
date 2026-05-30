module Admin
  # Lightweight CRUD over Tag rows. Auto-creation happens in PhrasesController
  # / Contacts edit form via chip-input; this controller is for cleanup
  # (rename/delete/inspect). Tenant-scoped: each tenant sees only their
  # own tags.
  class TagsController < BaseController
    def index
      @tags = Tag.for_tenant(viewing_tenant).order(:name).to_a
      # Precompute counts with two grouped queries instead of 2N COUNTs in the
      # view (PERF-3).
      tag_ids = @tags.map(&:id)
      @phrase_counts  = PhraseTag.where(tag_id: tag_ids).group(:tag_id).count
      @contact_counts = ContactTag.where(tag_id: tag_ids).group(:tag_id).count
    end

    def destroy
      tag = viewing_tenant.tags.find(params[:id])
      tag.destroy
      redirect_to admin_tags_path, notice: "Tag '#{tag.name}' removed."
    end
  end
end
