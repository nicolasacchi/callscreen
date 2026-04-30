module Admin
  class DashboardController < BaseController
    def index
      tenant = viewing_tenant
      today_by_status = tenant.calls.today.group(:status).count
      @stats = {
        total_today:    today_by_status.values.sum,
        spam_today:     today_by_status["spam"]  || 0,
        legit_today:    today_by_status["legit"] || 0,
        recorded_today: tenant.calls.today.where.not(recording_url: nil).count,
        total_all:      tenant.calls.count,
        contacts:       tenant.contacts.count,
        whitelisted:    tenant.contacts.whitelisted.count,
        blacklisted:    tenant.contacts.blacklisted.count
      }

      @daily_calls = tenant.calls.where("created_at > ?", 30.days.ago)
                                 .group_by_day(:created_at)
                                 .count

      @daily_spam = tenant.calls.spam.where("created_at > ?", 30.days.ago)
                                .group_by_day(:created_at)
                                .count

      @recent_calls  = tenant.calls.recent.includes(:contact).limit(15)
      @recent_audits = AuditLog.where(tenant_id: tenant.id).recent.includes(:actor).limit(10)
    end
  end
end
