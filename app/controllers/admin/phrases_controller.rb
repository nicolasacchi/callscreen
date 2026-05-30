module Admin
  # CRUD over user-authored Phrase rows. System phrases (tenant_id: nil)
  # are visible-only here — never editable or deletable from the tenant
  # UI. Operator-only edits live in v1.5.
  class PhrasesController < BaseController
    before_action :load_phrase, only: [ :edit, :update, :destroy, :show, :rerender ]

    def index
      shared = Phrase.where(tenant_id: nil)
      own    = Phrase.where(tenant_id: viewing_tenant.id)
      scope  = Phrase.where(id: shared.pluck(:id) + own.pluck(:id))
      scope  = scope.where(time_of_day: params[:tod])      if params[:tod].present?
      scope  = scope.where(day_of_week: params[:dow])      if params[:dow].present?
      scope  = scope.where(render_status: params[:status]) if params[:status].present?
      scope  = scope.joins(:phrase_tags).where(phrase_tags: { tag_id: params[:tag_id] }).distinct if params[:tag_id].present?
      @phrases = paginate(scope.order(:tenant_id, :slug))
      @tags    = Tag.for_tenant(viewing_tenant).order(:name)
    end

    def show; end

    def new
      @phrase = viewing_tenant.phrases.new(time_of_day: "any", kind: "user")
    end

    def edit; end

    def create
      @phrase = viewing_tenant.phrases.new(phrase_params.merge(kind: "user"))
      assign_tags(@phrase)
      if @phrase.save
        audit("phrase_create", @phrase, slug: @phrase.slug)
        redirect_to admin_phrase_path(@phrase), notice: "Phrase created. Render queued."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def update
      assign_tags(@phrase)
      if @phrase.update(phrase_params)
        audit("phrase_update", @phrase, slug: @phrase.slug)
        redirect_to admin_phrase_path(@phrase), notice: "Phrase updated. Re-render queued."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @phrase.destroy
      audit("phrase_destroy", @phrase, slug: @phrase.slug)
      redirect_to admin_phrases_path, notice: "Phrase removed."
    end

    def rerender
      PhraseRenderJob.perform_later(@phrase.id)
      @phrase.update!(render_status: "pending", last_render_error: nil)
      redirect_to admin_phrases_path, notice: "Render queued."
    end

    private

    def load_phrase
      # Tenants can read any phrase visible to them, but only mutate
      # their own (kind: "user", tenant_id: tenant.id).
      action = action_name.to_s
      writeable = %w[edit update destroy rerender].include?(action)
      scope = writeable ? viewing_tenant.phrases.where(kind: "user")
                        : Phrase.visible_to(viewing_tenant)
      @phrase = scope.find(params[:id])
    end

    def phrase_params
      params.require(:phrase).permit(:slug, :label, :text_it, :text_en, :time_of_day, :day_of_week)
    end

    def assign_tags(phrase)
      return unless params.dig(:phrase, :tag_names)
      Tag.assign_csv(phrase, params[:phrase][:tag_names], tenant: viewing_tenant)
    end

    def audit(action_name, subject, metadata = {})
      AuditLog.record(action: action_name, subject: subject,
                      tenant: viewing_tenant, actor: current_tenant, **metadata)
    end
  end
end
