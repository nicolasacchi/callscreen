module Admin
  class RecordingsController < BaseController
    def index
      scope = viewing_tenant.calls
                            .where("recording_local_path IS NOT NULL OR recording_url IS NOT NULL")
                            .recent
                            .includes(:contact)
      @calls = paginate(scope)
    end
  end
end
