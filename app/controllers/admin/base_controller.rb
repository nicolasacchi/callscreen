module Admin
  class BaseController < ApplicationController
    before_action :authenticate_admin_user!
    layout "admin"

    private

    def paginate(scope, per: 25)
      page = [ params[:page].to_i, 1 ].max
      total = scope.count
      offset = (page - 1) * per
      records = scope.offset(offset).limit(per)
      @pagination = {
        current_page: page,
        per_page: per,
        total_count: total,
        total_pages: (total.to_f / per).ceil
      }
      records
    end
  end
end
