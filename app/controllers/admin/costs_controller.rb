module Admin
  class CostsController < BaseController
    PERIODS = { "7d" => 7, "30d" => 30, "90d" => 90 }.freeze
    DEFAULT_PERIOD = "30d".freeze
    DEFAULT_TZ = "Europe/Rome".freeze

    def index
      @period_key  = PERIODS.key?(params[:period]) ? params[:period] : DEFAULT_PERIOD
      @period_days = PERIODS.fetch(@period_key)

      @scope_label, scope = resolve_scope
      window = @period_days.days.ago
      tz     = (current_tenant&.time_zone.presence || DEFAULT_TZ)

      windowed = scope.where("created_at > ?", window)

      @total_telnyx   = windowed.sum(:telnyx_cost_usd).to_f
      @total_moonshot = windowed.sum(:moonshot_cost_usd).to_f
      @total          = @total_telnyx + @total_moonshot
      @call_count     = windowed.count
      @avg_per_call   = @call_count.zero? ? 0.0 : @total / @call_count

      @chart_data = [
        { name: "Telnyx",
          data: windowed.group_by_day(:created_at, last: @period_days, time_zone: tz)
                        .sum(:telnyx_cost_usd) },
        { name: "Moonshot",
          data: windowed.group_by_day(:created_at, last: @period_days, time_zone: tz)
                        .sum(:moonshot_cost_usd) }
      ]

      @heatmap = windowed
        .group_by_day_of_week(:created_at, time_zone: tz)
        .group_by_hour_of_day(:created_at, time_zone: tz)
        .sum(Arel.sql("COALESCE(telnyx_cost_usd, 0) + COALESCE(moonshot_cost_usd, 0)"))
      @heatmap_max = (@heatmap.values.map(&:to_f).max || 0.0)

      ranked = windowed
        .group(:contact_id, :from_number)
        .order(Arel.sql("SUM(COALESCE(telnyx_cost_usd, 0) + COALESCE(moonshot_cost_usd, 0)) DESC"))
        .limit(10)
        .pluck(:contact_id, :from_number,
               Arel.sql("SUM(COALESCE(telnyx_cost_usd, 0) + COALESCE(moonshot_cost_usd, 0))"))
      contacts_by_id = Contact.where(id: ranked.map(&:first).compact).index_by(&:id)
      @top_contacts = ranked.map { |cid, num, total|
        { contact: contacts_by_id[cid], from_number: num, total: total.to_f }
      }

      if super_admin?
        per_tenant = Call.where("created_at > ?", window)
                         .group(:tenant_id)
                         .pluck(:tenant_id,
                                Arel.sql("SUM(COALESCE(telnyx_cost_usd, 0) + COALESCE(moonshot_cost_usd, 0))"),
                                Arel.sql("COUNT(*)"))
        tenants_by_id = Tenant.where(id: per_tenant.map(&:first)).index_by(&:id)
        @per_tenant = per_tenant.map { |tid, total, count|
          { tenant: tenants_by_id[tid], total: total.to_f, count: count }
        }.sort_by { |row| -row[:total] }
      end
    end

    private

    # Super-admin with no ?tenant_id: cross-tenant view (Call.all).
    # Super-admin with ?tenant_id: that tenant's calls only.
    # Regular tenant: their own calls only.
    def resolve_scope
      if super_admin? && params[:tenant_id].blank?
        ["All tenants", Call.all]
      else
        t = viewing_tenant
        ["Tenant: #{t.display_name}", t.calls]
      end
    end
  end
end
